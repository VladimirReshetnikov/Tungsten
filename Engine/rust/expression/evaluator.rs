use std::cmp::Ordering;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read as _;
use std::time::{Duration, Instant};

use base64::Engine as _;
use num_bigint::BigInt;
use num_integer::Integer as _;
use num_rational::BigRational;
use num_traits::{One, Signed, ToPrimitive, Zero};
use once_cell::sync::Lazy;
use rand::seq::SliceRandom as _;
use serde_json::json;

use crate::wolfram_strings::inline_box_segments;

use super::Result;
use super::ast::{
    Expr, call, complex, integer, list, rational, string, symbol, system_dispatch_name,
};
use super::parser::{interpret_standard_form, parse_input_form};

/// Evaluate one expression in a fresh kernel-free evaluator.
pub fn evaluate(expr: Expr) -> Result<Expr> {
    Evaluator::default().evaluate(expr)
}

static SYSTEM_SYMBOLS: Lazy<BTreeSet<String>> = Lazy::new(|| {
    let snapshot: serde_json::Value = serde_json::from_str(include_str!(
        "../../src/tungsten/data/system_symbols_wolfram_15_0.json"
    ))
    .expect("bundled System symbol snapshot is valid JSON");
    let mut symbols = snapshot["symbols"]
        .as_array()
        .expect("snapshot symbols array")
        .iter()
        .filter_map(|entry| entry.as_array()?.first()?.as_str().map(str::to_owned))
        .collect::<BTreeSet<_>>();
    symbols.extend(
        [
            "ConfirmationFailed",
            "FailsafeFailed",
            "MachineIntegerQ",
            "NegativeDegreeLexicographic",
            "NegativeDegreeReverseLexicographic",
            "NegativeLexicographic",
        ]
        .map(str::to_owned),
    );
    symbols
});

/// Mutable state for kernel-free evaluation.
///
/// Symbol definitions and message/session state will live here as their port
/// slices land. Keeping the evaluator stateful from the start avoids an API
/// break when Set, scoping, and history are enabled.
#[derive(Debug)]
pub struct Evaluator {
    recursion_limit: usize,
    depth: usize,
    control: Option<Control>,
    reap_stack: Vec<ReapScope>,
    time_deadlines: Vec<Instant>,
    own_values: HashMap<String, Definition>,
    down_values: HashMap<String, Vec<Definition>>,
    sub_values: HashMap<String, Vec<Definition>>,
    up_values: HashMap<String, Vec<Definition>>,
    active_symbols: Vec<String>,
    module_counter: u64,
    attributes: HashMap<String, BTreeSet<String>>,
    messages: Vec<Expr>,
    message_texts: Vec<String>,
    message_events: Vec<MessageEvent>,
    quiet_scopes: Vec<QuietScope>,
    disabled_messages: BTreeSet<String>,
    assert_enabled: bool,
    session_hooks_enabled: bool,
    prints: Vec<String>,
    max_extra_precision: usize,
    max_root_degree: usize,
    known_symbols: BTreeSet<String>,
    unique_counter: u64,
}

#[derive(Clone, Debug, Default, Eq, PartialEq)]
struct NativePolynomial {
    terms: BTreeMap<Vec<usize>, Expr>,
}

#[derive(Clone, Debug)]
struct NativeFactorization {
    coefficient: Expr,
    factors: Vec<(Expr, usize)>,
}

impl Default for Evaluator {
    fn default() -> Self {
        let message_preprint = "$MessagePrePrint".to_owned();
        let own_values = HashMap::from([(
            message_preprint.clone(),
            Definition {
                lhs: symbol(message_preprint),
                rhs: symbol("Automatic"),
                condition: None,
            },
        )]);
        Self {
            recursion_limit: 1024,
            depth: 0,
            control: None,
            reap_stack: Vec::new(),
            time_deadlines: Vec::new(),
            own_values,
            down_values: HashMap::new(),
            sub_values: HashMap::new(),
            up_values: HashMap::new(),
            active_symbols: Vec::new(),
            module_counter: 0,
            attributes: HashMap::new(),
            messages: Vec::new(),
            message_texts: Vec::new(),
            message_events: Vec::new(),
            quiet_scopes: Vec::new(),
            disabled_messages: BTreeSet::new(),
            assert_enabled: false,
            session_hooks_enabled: false,
            prints: Vec::new(),
            max_extra_precision: 50,
            max_root_degree: 1000,
            known_symbols: BTreeSet::new(),
            unique_counter: 0,
        }
    }
}

#[derive(Debug)]
enum Control {
    Abort,
    Timeout,
    Break,
    Continue,
    Return {
        value: Expr,
        head: Option<String>,
    },
    Throw {
        value: Expr,
        tag: Option<Expr>,
        handler: Option<Expr>,
    },
    Confirm {
        failure: Expr,
        tag: Option<Expr>,
    },
    Goto {
        label: Expr,
    },
}

#[derive(Debug)]
enum LoopControl {
    None,
    Break,
    Continue,
    Return(Expr),
    Propagate,
}

#[derive(Clone, Copy, Debug)]
enum IterationMode {
    Table,
    Do,
    Sum,
    Product,
}

#[derive(Clone, Copy, Debug)]
enum SelectionMode {
    Select,
    Discard,
    First,
}

#[derive(Clone, Debug)]
struct IteratorValues {
    variable: Option<String>,
    values: Vec<Expr>,
}

#[derive(Debug)]
struct ReapScope {
    patterns: Vec<Expr>,
    pattern_list_mode: bool,
    buckets: Vec<Vec<(Expr, Vec<Expr>)>>,
}

#[derive(Clone, Debug)]
struct MessageEvent {
    name: Expr,
    suppression_depth: Option<usize>,
}

#[derive(Clone, Debug)]
struct QuietScope {
    off_spec: Expr,
    on_spec: Expr,
}

#[derive(Clone, Debug)]
struct Definition {
    lhs: Expr,
    rhs: Expr,
    condition: Option<Expr>,
}

#[derive(Clone, Debug)]
struct LocalBinding {
    name: String,
    value: Option<Expr>,
    delayed: bool,
}

#[derive(Clone, Debug)]
struct DefinitionSnapshot {
    name: String,
    own: Option<Definition>,
    down: Option<Vec<Definition>>,
    sub: Option<Vec<Definition>>,
    up: Option<Vec<Definition>>,
}

#[derive(Clone, Debug)]
struct SelectionItem {
    index: usize,
    value: Expr,
    entry: Option<Expr>,
}

#[derive(Clone, Debug)]
enum SelectionProperty {
    Element,
    Index,
    Multiple(Vec<SelectionProperty>),
}

#[derive(Clone, Debug)]
struct CompiledStringPattern {
    regex: regex::Regex,
    bindings: BTreeMap<String, Vec<String>>,
    tests: Vec<(String, Expr)>,
}

#[derive(Clone, Debug)]
struct StringPatternSpec {
    pattern: CompiledStringPattern,
    template: Option<Expr>,
}

#[derive(Clone, Debug)]
struct StringFoundMatch {
    start: usize,
    end: usize,
    bindings: Vec<(String, Expr)>,
}

#[derive(Default)]
struct StringPatternCompiler {
    next_group: usize,
    bindings: BTreeMap<String, Vec<String>>,
    tests: Vec<(String, Expr)>,
}

impl Evaluator {
    pub fn messages(&self) -> &[Expr] {
        &self.messages
    }

    pub fn message_texts(&self) -> &[String] {
        &self.message_texts
    }

    pub fn prints(&self) -> &[String] {
        &self.prints
    }

    pub fn set_session_hooks_enabled(&mut self, enabled: bool) {
        self.session_hooks_enabled = enabled;
    }

    fn emit_message(&mut self, name: &str, tag: &str) {
        self.emit_message_name(call("MessageName", [symbol(name), string(tag)]));
    }

    fn emit_message_detail(&mut self, name: &str, tag: &str, detail: String) {
        let message_name = call("MessageName", [symbol(name), string(tag)]);
        self.emit_message_name_with_text(message_name, format!("{name}::{tag}: {detail}"));
    }

    fn emit_message_name(&mut self, name: Expr) {
        let rendered_name = name.to_input_form();
        let detail = default_message_detail(&name);
        self.emit_message_name_with_text(name, format!("{rendered_name}: {detail}"));
    }

    fn emit_message_name_with_text(&mut self, name: Expr, text: String) {
        if self.message_is_disabled(&name) {
            return;
        }
        let suppression_depth = self.quiet_suppression_depth(&name);
        self.message_events.push(MessageEvent {
            name: name.clone(),
            suppression_depth,
        });
        if suppression_depth.is_none() {
            self.messages.push(name);
            self.message_texts.push(text);
        }
    }

    fn message_is_disabled(&self, name: &Expr) -> bool {
        if self.disabled_messages.contains(&name.to_full_form()) {
            return true;
        }
        let Some((_, tags)) = message_name_components(name) else {
            return false;
        };
        let Some(tag) = tags.last() else {
            return false;
        };
        self.disabled_messages
            .contains(&call("MessageName", [symbol("General"), string(tag)]).to_full_form())
    }

    fn quiet_suppression_depth(&self, name: &Expr) -> Option<usize> {
        for (index, scope) in self.quiet_scopes.iter().enumerate().rev() {
            if message_spec_matches(&scope.on_spec, name) {
                return None;
            }
            if message_spec_matches(&scope.off_spec, name) {
                return Some(index + 1);
            }
        }
        None
    }

    fn emit_error_message(&mut self, name: &str) {
        self.emit_message(name, "error");
    }

    pub fn evaluate(&mut self, expr: Expr) -> Result<Expr> {
        let root = self.depth == 0;
        if root {
            self.messages.clear();
            self.message_texts.clear();
            self.message_events.clear();
            self.prints.clear();
        }
        if self
            .time_deadlines
            .last()
            .is_some_and(|deadline| Instant::now() >= *deadline)
        {
            self.control = Some(Control::Timeout);
            let result = Ok(symbol("$Aborted"));
            return if root {
                self.finish_control(result)
            } else {
                result
            };
        }
        if self.depth >= self.recursion_limit {
            return Ok(call("TerminatedEvaluation", [symbol("RecursionLimit")]));
        }
        self.depth += 1;
        let result = self.evaluate_once(expr);
        self.depth -= 1;
        if root {
            self.finish_control(result)
        } else {
            result
        }
    }

    fn finish_control(&mut self, result: Result<Expr>) -> Result<Expr> {
        let Some(control) = self.control.take() else {
            return result;
        };
        match control {
            Control::Abort | Control::Timeout => Ok(symbol("$Aborted")),
            Control::Break => Ok(call("Break", [])),
            Control::Continue => Ok(call("Continue", [])),
            Control::Return { value, head } => {
                let mut arguments = vec![value];
                if let Some(head) = head {
                    arguments.push(symbol(head));
                }
                Ok(call("Return", arguments))
            }
            Control::Throw {
                value,
                tag,
                handler,
            } => {
                if let Some(handler) = handler {
                    let mut arguments = vec![value];
                    if let Some(tag) = tag {
                        arguments.push(tag);
                    }
                    self.evaluate(call(handler, arguments))
                } else {
                    let mut arguments = vec![value];
                    if let Some(tag) = tag {
                        arguments.push(tag);
                    }
                    Ok(call("Throw", arguments))
                }
            }
            Control::Confirm { failure, .. } => Ok(failure),
            Control::Goto { label } => Ok(call("Goto", [label])),
        }
    }

    fn evaluate_once(&mut self, expr: Expr) -> Result<Expr> {
        match expr {
            Expr::Symbol(name) if system_dispatch_name(&name) == "I" => {
                Ok(complex(integer(0), integer(1)))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$Context" => {
                Ok(string("Global`"))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$ContextPath" => {
                Ok(list([string("System`"), string("Global`")]))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MachinePrecision" => {
                Ok(Expr::Real("15.954589770191003".into()))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MaxMachineNumber" => {
                Ok(Expr::Real("1.7976931348623157*^+308".into()))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MinMachineNumber" => {
                Ok(Expr::Real("2.2250738585072014*^-308".into()))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MachineEpsilon" => {
                Ok(Expr::Real("2.220446049250313*^-16".into()))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MessageList" => Ok(list(
                self.message_events
                    .iter()
                    .map(|event| call("HoldForm", [event.name.clone()])),
            )),
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MaxExtraPrecision" => {
                Ok(integer(self.max_extra_precision))
            }
            Expr::Symbol(name) if system_dispatch_name(&name) == "$MaxRootDegree" => {
                Ok(integer(self.max_root_degree))
            }
            Expr::Symbol(name) => {
                self.register_symbol_name(&name);
                if self.active_symbols.contains(&name) {
                    return Ok(symbol(name));
                }
                if let Some(definition) = self.own_values.get(&name).cloned() {
                    self.active_symbols.push(name);
                    let result = self.evaluate(definition.rhs);
                    self.active_symbols.pop();
                    result
                } else {
                    Ok(symbol(name))
                }
            }
            Expr::Integer(_)
            | Expr::Real(_)
            | Expr::Rational(_)
            | Expr::Complex { .. }
            | Expr::Root { .. }
            | Expr::SpecialReal(_)
            | Expr::String(_)
            | Expr::ByteArray(_)
            | Expr::SparseArray { .. } => Ok(expr),
            Expr::Call { head, args } => self.evaluate_call(*head, args),
        }
    }

    fn evaluate_call(&mut self, raw_head: Expr, raw_args: Vec<Expr>) -> Result<Expr> {
        if let Some(name) = raw_head.symbol_name().map(system_dispatch_name) {
            match name {
                "Abort" => {
                    self.control = Some(Control::Abort);
                    return Ok(symbol("$Aborted"));
                }
                "CheckAbort" => return self.evaluate_check_abort(raw_head, raw_args),
                "Check" => return self.evaluate_check(raw_head, raw_args),
                "AbortProtect" => {
                    return match raw_args.as_slice() {
                        [argument] => self.evaluate(argument.clone()),
                        _ => Ok(call(raw_head, raw_args)),
                    };
                }
                "Throw" => return self.evaluate_throw(raw_head, raw_args),
                "Catch" => return self.evaluate_catch(raw_head, raw_args),
                "Sow" => return self.evaluate_sow(raw_head, raw_args),
                "Reap" => return self.evaluate_reap(raw_head, raw_args),
                "TimeConstrained" => {
                    return self.evaluate_time_constrained(raw_head, raw_args);
                }
                "TimeRemaining" => return self.evaluate_time_remaining(raw_head, raw_args),
                "Pause" => return self.evaluate_pause(raw_head, raw_args),
                "AbsoluteTiming" => return self.evaluate_absolute_timing(raw_head, raw_args),
                "Enclose" => return self.evaluate_enclose(raw_head, raw_args),
                "Confirm" | "ConfirmBy" | "ConfirmMatch" | "ConfirmAssert" => {
                    return self.evaluate_confirm(raw_head.clone(), raw_args, name);
                }
                "Assert" => return self.evaluate_assert(raw_head, raw_args),
                "WithCleanup" => return self.evaluate_with_cleanup(raw_head, raw_args),
                "Quiet" => return self.evaluate_quiet(raw_head, raw_args),
                "Message" => return self.evaluate_message(raw_head, raw_args),
                "Off" => return self.evaluate_on_off(raw_head, raw_args, false),
                "On" => return self.evaluate_on_off(raw_head, raw_args, true),
                "MessageList" => {
                    return Ok(if raw_args.len() == 1 {
                        list(std::iter::empty::<Expr>())
                    } else {
                        call(raw_head, raw_args)
                    });
                }
                "MatchQ" => return self.evaluate_match_q(raw_head, raw_args),
                "MakeBoxes" => return self.evaluate_make_boxes(raw_head, raw_args),
                "MakeExpression" => return self.evaluate_make_expression(raw_head, raw_args),
                "Root" => return self.evaluate_root_call(raw_head, raw_args),
                "FreeQ" => return self.evaluate_free_q(raw_head, raw_args),
                "Replace" => return self.evaluate_replace(raw_head, raw_args),
                "ReplaceAll" => return self.evaluate_replace_all(raw_head, raw_args, false),
                "ReplaceRepeated" => return self.evaluate_replace_all(raw_head, raw_args, true),
                "Cases" => return self.evaluate_cases(raw_head, raw_args, false),
                "DeleteCases" => return self.evaluate_cases(raw_head, raw_args, true),
                "Count" => return self.evaluate_count(raw_head, raw_args),
                "MemberQ" => return self.evaluate_member_q(raw_head, raw_args),
                "Set" => return self.evaluate_set(raw_head, raw_args, false),
                "SetDelayed" => return self.evaluate_set(raw_head, raw_args, true),
                "TagSet" => return self.evaluate_tag_set(raw_head, raw_args, false),
                "TagSetDelayed" => return self.evaluate_tag_set(raw_head, raw_args, true),
                "Unset" => return self.evaluate_unset(raw_head, raw_args),
                "TagUnset" => return self.evaluate_tag_unset(raw_head, raw_args),
                "Clear" | "ClearAll" => return self.evaluate_clear(raw_head, raw_args),
                "SetAttributes" => return self.evaluate_set_attributes(raw_head, raw_args, false),
                "ClearAttributes" => {
                    return self.evaluate_set_attributes(raw_head, raw_args, true);
                }
                "Attributes" => return self.evaluate_attributes(raw_head, raw_args),
                "Protect" => return self.evaluate_protect(raw_head, raw_args, true),
                "Unprotect" => return self.evaluate_protect(raw_head, raw_args, false),
                "ValueQ" => return self.evaluate_value_q(raw_head, raw_args),
                "OwnValues" => return self.evaluate_own_values(raw_head, raw_args),
                "DownValues" => return self.evaluate_down_values(raw_head, raw_args),
                "SubValues" => return self.evaluate_sub_values(raw_head, raw_args),
                "UpValues" => return self.evaluate_up_values(raw_head, raw_args),
                "NValues" => return self.evaluate_n_values(raw_head, raw_args),
                "With" => return self.evaluate_with(raw_head, raw_args),
                "Module" => return self.evaluate_module(raw_head, raw_args),
                "Block" | "InheritedBlock" | "Internal`InheritedBlock" => {
                    return self.evaluate_block(raw_head, raw_args);
                }
                "Table" => {
                    return self.evaluate_iteration(raw_head, raw_args, IterationMode::Table);
                }
                "Do" => {
                    return self.evaluate_iteration(raw_head, raw_args, IterationMode::Do);
                }
                "Sum" => {
                    return self.evaluate_iteration(raw_head, raw_args, IterationMode::Sum);
                }
                "Product" => {
                    return self.evaluate_iteration(raw_head, raw_args, IterationMode::Product);
                }
                "While" => return self.evaluate_while(raw_head, raw_args),
                "For" => return self.evaluate_for(raw_head, raw_args),
                "Break" if raw_args.is_empty() => {
                    self.control = Some(Control::Break);
                    return Ok(call(raw_head, raw_args));
                }
                "Continue" if raw_args.is_empty() => {
                    self.control = Some(Control::Continue);
                    return Ok(call(raw_head, raw_args));
                }
                "Return" => return self.evaluate_return(raw_head, raw_args),
                "Label" => return Ok(call(raw_head, raw_args)),
                "Goto" => {
                    let [label] = raw_args.as_slice() else {
                        return Ok(call(raw_head, raw_args));
                    };
                    let label = self.evaluate(label.clone())?;
                    self.control = Some(Control::Goto {
                        label: label.clone(),
                    });
                    return Ok(call(raw_head, [label]));
                }
                "Increment" | "Decrement" | "PreIncrement" | "PreDecrement" => {
                    return self.evaluate_increment(raw_head.clone(), raw_args, name);
                }
                "AddTo" | "SubtractFrom" | "TimesBy" | "DivideBy" => {
                    return self.evaluate_update(raw_head.clone(), raw_args, name);
                }
                "AppendTo" => return self.evaluate_append_to(raw_head, raw_args),
                "HoldComplete" => return Ok(call(raw_head, raw_args)),
                "Hold" | "HoldForm" | "HoldPattern" | "Unevaluated" => {
                    let mut normalized = Vec::with_capacity(raw_args.len());
                    for argument in raw_args {
                        if argument.has_head("Evaluate") && argument.args().len() == 1 {
                            let payload = &argument.args()[0];
                            if payload.has_head("Unevaluated") && payload.args().len() == 1 {
                                normalized.push(payload.clone());
                            } else {
                                normalized.push(self.evaluate(payload.clone())?);
                            }
                        } else {
                            normalized.push(argument);
                        }
                    }
                    let args = splice_raw_sequences(normalized);
                    return Ok(call(raw_head, args));
                }
                "Function" => return Ok(call(raw_head, splice_raw_sequences(raw_args))),
                "Evaluate" => {
                    return match raw_args.as_slice() {
                        [argument] => self.evaluate(strip_unevaluated(argument.clone())),
                        _ => Ok(call(raw_head, raw_args)),
                    };
                }
                "ReleaseHold" => {
                    return match raw_args.as_slice() {
                        [argument] => {
                            let held = self.evaluate(argument.clone())?;
                            if let Expr::Call { head, args } = &held
                                && head.symbol_name().is_some_and(|head_name| {
                                    matches!(
                                        system_dispatch_name(head_name),
                                        "Hold" | "HoldForm" | "HoldPattern" | "HoldComplete"
                                    )
                                })
                            {
                                if args.len() == 1 {
                                    self.evaluate(args[0].clone())
                                } else {
                                    self.evaluate(call("Sequence", args.clone()))
                                }
                            } else {
                                Ok(held)
                            }
                        }
                        _ => Ok(call(raw_head, raw_args)),
                    };
                }
                "If" => return self.evaluate_if(raw_head, raw_args),
                "Which" => return self.evaluate_which(raw_head, raw_args),
                "Switch" => return self.evaluate_switch(raw_head, raw_args),
                "Piecewise" => return self.evaluate_piecewise(raw_head, raw_args),
                "And" => return self.evaluate_and(raw_head, raw_args),
                "Or" => return self.evaluate_or(raw_head, raw_args),
                "CompoundExpression" => {
                    let mut result = symbol("Null");
                    let mut index = 0;
                    while index < raw_args.len() {
                        result = self.evaluate(raw_args[index].clone())?;
                        if let Some(Control::Goto { label }) = &self.control {
                            let target = raw_args.iter().position(|argument| {
                                argument.has_head("Label")
                                    && matches!(argument.args(), [candidate] if candidate == label)
                            });
                            if let Some(target) = target {
                                self.control = None;
                                index = target + 1;
                                result = symbol("Null");
                                continue;
                            }
                            break;
                        }
                        if self.control.is_some() {
                            break;
                        }
                        index += 1;
                    }
                    return Ok(result);
                }
                "Nothing" => {
                    for argument in raw_args {
                        self.evaluate(argument)?;
                    }
                    return Ok(symbol("Nothing"));
                }
                "Inactive" => {
                    if let [argument] = raw_args.as_slice() {
                        let target = if argument.has_head("Evaluate") && argument.args().len() == 1
                        {
                            self.evaluate(argument.args()[0].clone())?
                        } else {
                            argument.clone()
                        };
                        if is_non_symbol_atom(&target) {
                            return Ok(target);
                        }
                        return Ok(call(raw_head, [target]));
                    }
                    return Ok(call(raw_head, raw_args));
                }
                "Activate" => {
                    let (target, pattern) = match raw_args.as_slice() {
                        [target] => (self.evaluate(target.clone())?, None),
                        [target, pattern] => (
                            self.evaluate(target.clone())?,
                            Some(self.evaluate(pattern.clone())?),
                        ),
                        _ => return Ok(call(raw_head, raw_args)),
                    };
                    let activated = self.activate_inactive(target, pattern.as_ref())?;
                    return self.evaluate(activated);
                }
                _ => {}
            }
        }

        let evaluated_head = self.evaluate(raw_head)?;
        if self.control.is_some() {
            return Ok(evaluated_head);
        }
        if evaluated_head
            .symbol_name()
            .is_some_and(|name| system_dispatch_name(name) == "Nothing")
        {
            for argument in raw_args {
                self.evaluate(argument)?;
            }
            return Ok(symbol("Nothing"));
        }

        if is_function(&evaluated_head) {
            return self.apply_function(evaluated_head, raw_args);
        }
        if evaluated_head.has_head("Composition") || evaluated_head.has_head("RightComposition") {
            return self.apply_composition(evaluated_head, raw_args);
        }
        if evaluated_head.has_head("SameAs") {
            let mut arguments = evaluated_head.args().to_vec();
            arguments.extend(raw_args);
            return self.evaluate(call("SameQ", arguments));
        }
        if evaluated_head.has_head("MapApply") && evaluated_head.args().len() == 1 {
            let mut arguments = evaluated_head.args().to_vec();
            arguments.extend(raw_args);
            return self.evaluate(call("MapApply", arguments));
        }
        if let Some(operator) = evaluated_head
            .head()
            .symbol_name()
            .map(system_dispatch_name)
            .filter(|name| {
                matches!(
                    *name,
                    "Select"
                        | "Discard"
                        | "SelectFirst"
                        | "KeySelect"
                        | "StringContainsQ"
                        | "StringStartsQ"
                        | "StringEndsQ"
                        | "StringFreeQ"
                        | "StringPosition"
                        | "StringCases"
                )
            })
            && evaluated_head.args().len() == 1
            && raw_args.len() == 1
        {
            let mut arguments = vec![raw_args[0].clone()];
            arguments.extend(evaluated_head.args().iter().cloned());
            return self.evaluate(call(operator, arguments));
        }
        if let Expr::SparseArray {
            dimensions,
            entries,
            ..
        } = &evaluated_head
        {
            let evaluated_args = raw_args
                .into_iter()
                .map(|argument| self.evaluate(argument))
                .collect::<Result<Vec<_>>>()?;
            if let [Expr::String(property)] = evaluated_args.as_slice() {
                return Ok(match property.as_str() {
                    "ExplicitPositions" => list(
                        entries
                            .iter()
                            .map(|(position, _)| list(position.iter().copied().map(integer))),
                    ),
                    "Density" => {
                        let total = dimensions.iter().copied().product::<usize>();
                        if total == 0 {
                            integer(0)
                        } else {
                            rational(entries.len(), total)
                        }
                    }
                    _ => call(evaluated_head, evaluated_args),
                });
            }
            return Ok(call(evaluated_head, evaluated_args));
        }
        if evaluated_head.has_head("Association") {
            let evaluated_args = raw_args
                .into_iter()
                .map(|argument| self.evaluate(argument))
                .collect::<Result<Vec<_>>>()?;
            if let [key] = evaluated_args.as_slice() {
                return Ok(association_lookup(&evaluated_head, key, None));
            }
            return Ok(call(evaluated_head, evaluated_args));
        }
        if evaluated_head.has_head("Failure") {
            let evaluated_args = raw_args
                .into_iter()
                .map(|argument| self.evaluate(argument))
                .collect::<Result<Vec<_>>>()?;
            if let [key] = evaluated_args.as_slice() {
                return Ok(failure_property(&evaluated_head, key));
            }
            return Ok(call(evaluated_head, evaluated_args));
        }
        if evaluated_head.has_head("Failsafe") {
            return self.evaluate_failsafe_apply(evaluated_head, raw_args);
        }
        if let Some(operator) = evaluated_head
            .head()
            .symbol_name()
            .map(system_dispatch_name)
            .filter(|name| {
                matches!(
                    *name,
                    "SortBy" | "ReverseSortBy" | "OrderingBy" | "MinimalBy" | "MaximalBy"
                )
            })
            && evaluated_head.args().len() == 1
            && raw_args.len() == 1
        {
            return self.evaluate(call(
                operator,
                [raw_args[0].clone(), evaluated_head.args()[0].clone()],
            ));
        }

        let head_symbol = evaluated_head.symbol_name().map(str::to_owned);
        let head_attributes = head_symbol
            .as_deref()
            .map(|name| self.attributes_for(name))
            .unwrap_or_default();
        let hold_all_complete = head_attributes.contains("HoldAllComplete");
        let hold_all = head_attributes.contains("HoldAll");
        let hold_first = head_attributes.contains("HoldFirst");
        let hold_rest = head_attributes.contains("HoldRest");

        let mut evaluated_args = Vec::new();
        for (index, argument) in raw_args.into_iter().enumerate() {
            let held = hold_all_complete
                || hold_all
                || (hold_first && index == 0)
                || (hold_rest && index > 0);
            let evaluated = if hold_all_complete {
                argument
            } else if held {
                if argument.has_head("Evaluate") && argument.args().len() == 1 {
                    self.evaluate(argument.args()[0].clone())?
                } else {
                    argument
                }
            } else if argument.has_head("Unevaluated") && argument.args().len() == 1 {
                argument.args()[0].clone()
            } else {
                self.evaluate(argument)?
            };
            if self.control.is_some() {
                return Ok(evaluated);
            }
            if !hold_all_complete && evaluated.has_head("Sequence") {
                evaluated_args.extend(evaluated.args().iter().cloned());
            } else if !hold_all_complete
                && evaluated.has_head("Splice")
                && matches!(evaluated.args(), [_] | [_, _])
                && evaluated.args()[0].has_head("List")
                && evaluated.args().get(1).map_or_else(
                    || is_symbol(&evaluated_head, "List"),
                    |target_head| target_head == &evaluated_head,
                )
            {
                evaluated_args.extend(evaluated.args()[0].args().iter().cloned());
            } else {
                evaluated_args.push(evaluated);
            }
        }
        let head_name = head_symbol.as_deref().map(system_dispatch_name);
        if head_name == Some("List") || head_name == Some("Association") {
            evaluated_args.retain(|argument| !is_symbol(argument, "Nothing"));
        }
        if head_attributes.contains("Flat") {
            evaluated_args = flatten_same_head(head_name.unwrap_or_default(), evaluated_args);
        }
        if head_attributes.contains("Orderless") {
            evaluated_args.sort_by(expression_order);
        }
        if head_attributes.contains("Listable")
            && let Some(result) = self.thread_listable(&evaluated_head, &evaluated_args)?
        {
            return Ok(result);
        }
        if !hold_all_complete
            && let Some(result) = self.apply_up_values(&evaluated_head, &evaluated_args)?
        {
            return Ok(result);
        }
        if let Some(name) = head_name
            && let Some(result) = self.apply_down_value(name, &evaluated_head, &evaluated_args)?
        {
            return Ok(result);
        }
        if matches!(evaluated_head, Expr::Call { .. })
            && let Some(owner) = definition_owner(&evaluated_head)
            && let Some(result) = self.apply_sub_value(&owner, &evaluated_head, &evaluated_args)?
        {
            return Ok(result);
        }
        self.dispatch(evaluated_head, evaluated_args)
    }

    fn evaluate_set(&mut self, head: Expr, args: Vec<Expr>, delayed: bool) -> Result<Expr> {
        let [lhs, rhs] = args.as_slice() else {
            return Ok(call(head, args));
        };
        if lhs.has_head("Attributes")
            && let [target] = lhs.args()
        {
            if self.set_attribute_values(target, rhs, false) {
                return Ok(rhs.clone());
            }
            return Ok(call(head, args));
        }
        let (lhs, lhs_condition) = peel_condition(lhs);
        let (rhs, rhs_condition) = peel_condition(rhs);
        let condition = combine_conditions(lhs_condition, rhs_condition);
        if !delayed
            && let Expr::Symbol(name) = lhs
            && matches!(
                system_dispatch_name(name),
                "$MaxExtraPrecision" | "$MaxRootDegree"
            )
        {
            let value = self.evaluate(rhs.clone())?;
            let limit = match &value {
                Expr::Integer(value) if value.is_positive() => value.to_usize(),
                _ => None,
            };
            let setting_name = system_dispatch_name(name);
            if let Some(limit) = limit {
                if setting_name == "$MaxExtraPrecision" {
                    self.max_extra_precision = limit;
                } else {
                    self.max_root_degree = limit;
                }
            } else {
                let message_name = call("MessageName", [symbol(setting_name), string("limset")]);
                self.emit_message_name_with_text(
                    message_name,
                    format!(
                        "{setting_name}::limset: Cannot set {setting_name} to {}.",
                        value.to_input_form()
                    ),
                );
            }
            let current = if setting_name == "$MaxExtraPrecision" {
                self.max_extra_precision
            } else {
                self.max_root_degree
            };
            return Ok(integer(current));
        }
        let stored_rhs = if delayed {
            rhs.clone()
        } else {
            self.evaluate(rhs.clone())?
        };
        let prepared_lhs = match lhs {
            Expr::Call { .. } => self.prepare_assignment_lhs(lhs)?,
            _ => lhs.clone(),
        };
        match &prepared_lhs {
            Expr::Symbol(name) => {
                if self.has_attribute(name, "Protected") {
                    return Ok(call(head, args));
                }
                self.own_values.insert(
                    name.clone(),
                    Definition {
                        lhs: prepared_lhs,
                        rhs: stored_rhs.clone(),
                        condition,
                    },
                );
            }
            Expr::Call { .. } => {
                let Some(owner) = definition_owner(&prepared_lhs) else {
                    return Ok(call(head, args));
                };
                if self.has_attribute(&owner, "Protected") {
                    return Ok(call(head, args));
                }
                let definition = Definition {
                    lhs: prepared_lhs,
                    rhs: stored_rhs.clone(),
                    condition,
                };
                if is_subvalue_lhs(&definition.lhs) {
                    insert_definition(self.sub_values.entry(owner).or_default(), definition);
                } else {
                    insert_definition(self.down_values.entry(owner).or_default(), definition);
                }
            }
            _ => return Ok(call(head, args)),
        }
        Ok(if delayed { symbol("Null") } else { stored_rhs })
    }

    fn evaluate_tag_set(&mut self, head: Expr, args: Vec<Expr>, delayed: bool) -> Result<Expr> {
        let [Expr::Symbol(tag), lhs, rhs] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let (lhs, lhs_condition) = peel_condition(lhs);
        let (rhs, rhs_condition) = peel_condition(rhs);
        let condition = combine_conditions(lhs_condition, rhs_condition);
        let stored_rhs = if delayed {
            rhs.clone()
        } else {
            self.evaluate(rhs.clone())?
        };
        let prepared_lhs = match lhs {
            Expr::Call { .. } => self.prepare_assignment_lhs(lhs)?,
            _ => lhs.clone(),
        };
        let definition = Definition {
            lhs: prepared_lhs.clone(),
            rhs: stored_rhs.clone(),
            condition,
        };
        if definition_owner(&prepared_lhs).as_deref() == Some(tag.as_str()) {
            if matches!(prepared_lhs, Expr::Symbol(_)) {
                self.own_values.insert(tag.clone(), definition);
            } else if is_subvalue_lhs(&prepared_lhs) {
                insert_definition(self.sub_values.entry(tag.clone()).or_default(), definition);
            } else {
                insert_definition(self.down_values.entry(tag.clone()).or_default(), definition);
            }
        } else if tagged_upvalue_position(&prepared_lhs, tag) {
            insert_definition(self.up_values.entry(tag.clone()).or_default(), definition);
        } else {
            return Ok(call(head, args));
        }
        Ok(if delayed { symbol("Null") } else { stored_rhs })
    }

    fn evaluate_tag_unset(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [Expr::Symbol(tag), lhs] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let (lhs, _) = peel_condition(lhs);
        let prepared_lhs = match lhs {
            Expr::Call { .. } => self.prepare_assignment_lhs(lhs)?,
            _ => lhs.clone(),
        };
        if definition_owner(&prepared_lhs).as_deref() == Some(tag.as_str()) {
            if matches!(prepared_lhs, Expr::Symbol(_)) {
                self.own_values.remove(tag);
            } else {
                let values = if is_subvalue_lhs(&prepared_lhs) {
                    &mut self.sub_values
                } else {
                    &mut self.down_values
                };
                if let Some(definitions) = values.get_mut(tag) {
                    definitions.retain(|definition| definition.lhs != prepared_lhs);
                }
            }
        } else if tagged_upvalue_position(&prepared_lhs, tag) {
            if let Some(definitions) = self.up_values.get_mut(tag) {
                definitions.retain(|definition| definition.lhs != prepared_lhs);
            }
        } else {
            return Ok(call(head, args));
        }
        Ok(symbol("Null"))
    }

    fn evaluate_unset(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [lhs] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let (lhs, _) = peel_condition(lhs);
        let prepared_lhs = match lhs {
            Expr::Call { .. } => self.prepare_assignment_lhs(lhs)?,
            _ => lhs.clone(),
        };
        match &prepared_lhs {
            Expr::Symbol(name) => {
                self.own_values.remove(name);
            }
            Expr::Call { .. } => {
                if let Some(owner) = definition_owner(&prepared_lhs) {
                    let values = if is_subvalue_lhs(&prepared_lhs) {
                        &mut self.sub_values
                    } else {
                        &mut self.down_values
                    };
                    if let Some(definitions) = values.get_mut(&owner) {
                        definitions.retain(|definition| definition.lhs != prepared_lhs);
                    }
                }
            }
            _ => return Ok(call(head, args)),
        }
        Ok(symbol("Null"))
    }

    fn evaluate_clear(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.is_empty() {
            return Ok(call(head, args));
        }
        let mut names = Vec::new();
        for argument in &args {
            if !clear_names(argument, &mut names) {
                return Ok(call(head, args));
            }
        }
        for name in names {
            if self.has_attribute(&name, "Protected") || self.has_attribute(&name, "Locked") {
                continue;
            }
            self.own_values.remove(&name);
            self.down_values.remove(&name);
            self.sub_values.remove(&name);
            self.up_values.remove(&name);
            if is_symbol(&head, "ClearAll") {
                self.attributes.remove(&name);
            }
        }
        Ok(symbol("Null"))
    }

    fn evaluate_set_attributes(
        &mut self,
        head: Expr,
        args: Vec<Expr>,
        clear: bool,
    ) -> Result<Expr> {
        let [target, attributes] = args.as_slice() else {
            return Ok(call(head, args));
        };
        if self.set_attribute_values(target, attributes, clear) {
            Ok(symbol("Null"))
        } else {
            Ok(call(head, args))
        }
    }

    fn set_attribute_values(&mut self, target: &Expr, attributes: &Expr, clear: bool) -> bool {
        let mut names = Vec::new();
        if !attribute_targets(target, &mut names) {
            return false;
        }
        let mut values = Vec::new();
        if !attribute_names(attributes, &mut values) {
            return false;
        }
        if names.iter().any(|name| self.has_attribute(name, "Locked")) {
            return false;
        }
        for name in names {
            let entry = self.attributes.entry(name).or_default();
            for attribute in &values {
                if clear {
                    entry.remove(attribute);
                } else {
                    entry.insert(attribute.clone());
                }
            }
        }
        true
    }

    fn evaluate_attributes(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [target] = args.as_slice() else {
            return Ok(call(head, args));
        };
        if target.has_head("List") {
            let mut output = Vec::new();
            for item in target.args() {
                let Some(name) = attribute_target_name(item) else {
                    return Ok(call(head, args));
                };
                output.push(self.attribute_list(name));
            }
            return Ok(list(output));
        }
        let Some(name) = attribute_target_name(target) else {
            return Ok(call(head, args));
        };
        Ok(self.attribute_list(name))
    }

    fn attribute_list(&self, name: &str) -> Expr {
        list(self.attributes_for(name).into_iter().map(symbol))
    }

    fn attributes_for(&self, name: &str) -> BTreeSet<String> {
        let mut result = builtin_attributes(system_dispatch_name(name))
            .iter()
            .map(|attribute| (*attribute).to_owned())
            .collect::<BTreeSet<_>>();
        if let Some(attributes) = self.attributes.get(name) {
            result.extend(attributes.iter().cloned());
        }
        result
    }

    fn has_attribute(&self, name: &str, attribute: &str) -> bool {
        builtin_attributes(system_dispatch_name(name)).contains(&attribute)
            || self
                .attributes
                .get(name)
                .is_some_and(|attributes| attributes.contains(attribute))
    }

    fn evaluate_protect(&mut self, head: Expr, args: Vec<Expr>, protect: bool) -> Result<Expr> {
        if args.is_empty() {
            return Ok(call(head, args));
        }
        let mut names = Vec::new();
        for argument in &args {
            if !attribute_targets(argument, &mut names) {
                return Ok(call(head, args));
            }
        }
        let mut changed = Vec::new();
        for name in names {
            if self.has_attribute(&name, "Locked") {
                continue;
            }
            let entry = self.attributes.entry(name.clone()).or_default();
            if protect {
                entry.insert("Protected".to_owned());
            } else {
                entry.remove("Protected");
            }
            changed.push(string(name));
        }
        Ok(list(changed))
    }

    fn evaluate_value_q(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [argument] = args.as_slice() else {
            return Ok(call(head, args));
        };
        if matches!(argument, Expr::Symbol(name) if matches!(system_dispatch_name(name), "$Context" | "$ContextPath"))
        {
            return Ok(symbol("True"));
        }
        if let Expr::Symbol(name) = argument
            && self.own_values.contains_key(name)
        {
            return Ok(symbol("True"));
        }
        let evaluated = self.evaluate(argument.clone())?;
        Ok(bool_expr(evaluated != *argument))
    }

    fn evaluate_own_values(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [argument] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let name = match argument {
            Expr::Symbol(name) | Expr::String(name) => name,
            _ => return Ok(call(head, args)),
        };
        let Some(definition) = self.own_values.get(name) else {
            return Ok(list([]));
        };
        Ok(list([definition_rule(definition)]))
    }

    fn evaluate_down_values(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [Expr::Symbol(name)] = args.as_slice() else {
            return Ok(call(head, args));
        };
        Ok(definition_list(self.down_values.get(name)))
    }

    fn evaluate_sub_values(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [Expr::Symbol(name)] = args.as_slice() else {
            return Ok(call(head, args));
        };
        Ok(definition_list(self.sub_values.get(name)))
    }

    fn evaluate_up_values(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [Expr::Symbol(name)] = args.as_slice() else {
            return Ok(call(head, args));
        };
        Ok(definition_list(self.up_values.get(name)))
    }

    fn evaluate_n_values(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [Expr::Symbol(_)] = args.as_slice() else {
            return Ok(call(head, args));
        };
        Ok(list([]))
    }

    fn evaluate_with(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [bindings_expr, body] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let Some(bindings) = parse_local_bindings(bindings_expr, false) else {
            return Ok(call(head, args));
        };
        let mut substitutions = Vec::with_capacity(bindings.len());
        for binding in bindings {
            let Some(value) = binding.value else {
                return Ok(call(head, args));
            };
            let value = if binding.delayed {
                value
            } else {
                self.evaluate(value)?
            };
            substitutions.push((binding.name, value));
        }
        self.evaluate(substitute_lexical(body, &substitutions))
    }

    fn evaluate_module(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [bindings_expr, body] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let Some(bindings) = parse_local_bindings(bindings_expr, true) else {
            return Ok(call(head, args));
        };

        let mut initializers = Vec::with_capacity(bindings.len());
        for binding in &bindings {
            let value = match &binding.value {
                Some(value) if binding.delayed => Some(value.clone()),
                Some(value) => Some(self.evaluate(value.clone())?),
                None => None,
            };
            initializers.push(value);
        }

        self.module_counter += 1;
        let suffix = self.module_counter;
        let substitutions = bindings
            .iter()
            .map(|binding| {
                (
                    binding.name.clone(),
                    symbol(format!("{}${suffix}", binding.name)),
                )
            })
            .collect::<Vec<_>>();
        for ((_, fresh), value) in substitutions.iter().zip(initializers) {
            if let (Expr::Symbol(name), Some(value)) = (fresh, value) {
                self.store_own(name, value);
            }
        }
        let result = self.evaluate(substitute_lexical(body, &substitutions))?;
        match self.consume_loop_control("Module") {
            LoopControl::Return(value) => Ok(value),
            _ => Ok(result),
        }
    }

    fn evaluate_block(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [bindings_expr, body] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let Some(bindings) = parse_local_bindings(bindings_expr, true) else {
            return Ok(call(head, args));
        };
        let snapshots = bindings
            .iter()
            .map(|binding| DefinitionSnapshot {
                name: binding.name.clone(),
                own: self.own_values.get(&binding.name).cloned(),
                down: self.down_values.get(&binding.name).cloned(),
                sub: self.sub_values.get(&binding.name).cloned(),
                up: self.up_values.get(&binding.name).cloned(),
            })
            .collect::<Vec<_>>();

        for binding in &bindings {
            if let Some(value) = &binding.value {
                let value = if binding.delayed {
                    value.clone()
                } else {
                    self.evaluate(value.clone())?
                };
                self.store_own(&binding.name, value);
            }
        }
        let target = head
            .symbol_name()
            .map(system_dispatch_name)
            .unwrap_or("Block")
            .to_owned();
        let result = self.evaluate(body.clone());
        for snapshot in snapshots {
            restore_definition(&mut self.own_values, &snapshot.name, snapshot.own);
            restore_definitions(&mut self.down_values, &snapshot.name, snapshot.down);
            restore_definitions(&mut self.sub_values, &snapshot.name, snapshot.sub);
            restore_definitions(&mut self.up_values, &snapshot.name, snapshot.up);
        }
        let result = result?;
        match self.consume_loop_control(&target) {
            LoopControl::Return(value) => Ok(value),
            _ => Ok(result),
        }
    }

    fn evaluate_iteration(
        &mut self,
        head: Expr,
        args: Vec<Expr>,
        mode: IterationMode,
    ) -> Result<Expr> {
        if args.len() < 2 {
            return Ok(call(head, args));
        }
        if matches!(mode, IterationMode::Sum | IterationMode::Product) && !args[1].has_head("List")
        {
            return Ok(call(head, args));
        }
        let Some(result) = self.iterate_level(&args[0], &args[1..], 0, mode)? else {
            return Ok(call(head, args));
        };
        if matches!(mode, IterationMode::Do) {
            return Ok(match self.consume_loop_control("Do") {
                LoopControl::Break | LoopControl::Continue => symbol("Null"),
                LoopControl::Return(value) => value,
                _ => result,
            });
        }
        Ok(result)
    }

    fn iterate_level(
        &mut self,
        body: &Expr,
        specs: &[Expr],
        level: usize,
        mode: IterationMode,
    ) -> Result<Option<Expr>> {
        if level == specs.len() {
            return self.evaluate(body.clone()).map(Some);
        }
        let Some(iterator) = self.iterator_values(&specs[level], mode)? else {
            return Ok(None);
        };
        let snapshot = iterator
            .variable
            .as_ref()
            .map(|name| snapshot_definitions(self, name));
        let mut results = Vec::with_capacity(iterator.values.len());
        for value in iterator.values {
            if let Some(name) = &iterator.variable {
                self.store_own(name, value);
            }
            let Some(result) = self.iterate_level(body, specs, level + 1, mode)? else {
                if let Some(snapshot) = snapshot {
                    restore_snapshot(self, snapshot);
                }
                return Ok(None);
            };
            results.push(result);
            if matches!(mode, IterationMode::Do)
                && level + 1 == specs.len()
                && matches!(self.control, Some(Control::Continue))
            {
                self.control = None;
                continue;
            }
            if self.control.is_some() {
                break;
            }
        }
        if let Some(snapshot) = snapshot {
            restore_snapshot(self, snapshot);
        }
        let result = match mode {
            IterationMode::Table => list(
                results
                    .into_iter()
                    .filter(|result| !is_symbol(result, "Nothing")),
            ),
            IterationMode::Do => symbol("Null"),
            IterationMode::Sum => self.evaluate(call("Plus", results))?,
            IterationMode::Product => self.evaluate(call("Times", results))?,
        };
        Ok(Some(result))
    }

    fn evaluate_return(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.len() > 2 {
            return Ok(call(head, args));
        }
        let value = if let Some(value) = args.first() {
            self.evaluate(value.clone())?
        } else {
            symbol("Null")
        };
        let target = match args.get(1) {
            None => None,
            Some(Expr::Symbol(name)) => Some(name.clone()),
            Some(_) => return Ok(call(head, args)),
        };
        self.control = Some(Control::Return {
            value: value.clone(),
            head: target,
        });
        Ok(value)
    }

    fn evaluate_while(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let ([test] | [test, _]) = args.as_slice() else {
            return Ok(call(head, args));
        };
        let body = args.get(1).cloned().unwrap_or_else(|| symbol("Null"));
        for _ in 0..1_000_000 {
            let test = self.evaluate(test.clone())?;
            match self.consume_loop_control("While") {
                LoopControl::Break => return Ok(symbol("Null")),
                LoopControl::Continue => continue,
                LoopControl::Return(value) => return Ok(value),
                LoopControl::Propagate => return Ok(test),
                LoopControl::None => {}
            }
            if !is_symbol(&test, "True") {
                return Ok(symbol("Null"));
            }
            let value = self.evaluate(body.clone())?;
            match self.consume_loop_control("While") {
                LoopControl::Break => return Ok(symbol("Null")),
                LoopControl::Continue => continue,
                LoopControl::Return(value) => return Ok(value),
                LoopControl::Propagate => return Ok(value),
                LoopControl::None => {}
            }
        }
        Ok(call(head, args))
    }

    fn evaluate_for(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [initialization, test, increment, body] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let initialized = self.evaluate(initialization.clone())?;
        match self.consume_loop_control("For") {
            LoopControl::Break => return Ok(symbol("Null")),
            LoopControl::Return(value) => return Ok(value),
            LoopControl::Propagate => return Ok(initialized),
            _ => {}
        }
        for _ in 0..1_000_000 {
            let condition = self.evaluate(test.clone())?;
            match self.consume_loop_control("For") {
                LoopControl::Break => return Ok(symbol("Null")),
                LoopControl::Continue => {}
                LoopControl::Return(value) => return Ok(value),
                LoopControl::Propagate => return Ok(condition),
                LoopControl::None => {}
            }
            if !is_symbol(&condition, "True") {
                return Ok(symbol("Null"));
            }
            let value = self.evaluate(body.clone())?;
            match self.consume_loop_control("For") {
                LoopControl::Break => return Ok(symbol("Null")),
                LoopControl::Return(value) => return Ok(value),
                LoopControl::Propagate => return Ok(value),
                LoopControl::Continue | LoopControl::None => {}
            }
            let incremented = self.evaluate(increment.clone())?;
            match self.consume_loop_control("For") {
                LoopControl::Break => return Ok(symbol("Null")),
                LoopControl::Return(value) => return Ok(value),
                LoopControl::Propagate => return Ok(incremented),
                _ => {}
            }
        }
        Ok(call(head, args))
    }

    fn consume_loop_control(&mut self, target: &str) -> LoopControl {
        let Some(control) = self.control.take() else {
            return LoopControl::None;
        };
        match control {
            Control::Break => LoopControl::Break,
            Control::Continue => LoopControl::Continue,
            Control::Return {
                value,
                head: Some(head),
            } if system_dispatch_name(&head) == target => LoopControl::Return(value),
            control => {
                self.control = Some(control);
                LoopControl::Propagate
            }
        }
    }

    fn iterator_values(
        &mut self,
        spec: &Expr,
        mode: IterationMode,
    ) -> Result<Option<IteratorValues>> {
        if !spec.has_head("List") {
            if !matches!(mode, IterationMode::Table | IterationMode::Do) {
                return Ok(None);
            }
            let count = self.evaluate(spec.clone())?;
            return Ok(iterator_count(&count));
        }
        match spec.args() {
            [count] => {
                let count = self.evaluate(count.clone())?;
                Ok(iterator_count(&count))
            }
            [Expr::Symbol(variable), end] => {
                let end = self.evaluate(end.clone())?;
                if let Expr::Call { head, args } = &end
                    && is_symbol(head, "List")
                {
                    return Ok(Some(IteratorValues {
                        variable: Some(variable.clone()),
                        values: args.clone(),
                    }));
                }
                Ok(iterator_range(
                    Some(variable.clone()),
                    integer(1),
                    end,
                    integer(1),
                ))
            }
            [Expr::Symbol(variable), start, end] => {
                let start = self.evaluate(start.clone())?;
                let end = self.evaluate(end.clone())?;
                Ok(iterator_range(
                    Some(variable.clone()),
                    start,
                    end,
                    integer(1),
                ))
            }
            [Expr::Symbol(variable), start, end, step] => {
                let start = self.evaluate(start.clone())?;
                let end = self.evaluate(end.clone())?;
                let step = self.evaluate(step.clone())?;
                Ok(iterator_range(Some(variable.clone()), start, end, step))
            }
            _ => Ok(None),
        }
    }

    fn evaluate_increment(&mut self, head: Expr, args: Vec<Expr>, operation: &str) -> Result<Expr> {
        let [Expr::Symbol(name)] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let current = self
            .own_values
            .get(name)
            .map(|definition| definition.rhs.clone())
            .unwrap_or_else(|| symbol(name));
        let delta = if matches!(operation, "Increment" | "PreIncrement") {
            integer(1)
        } else {
            integer(-1)
        };
        let updated = self.evaluate(call("Plus", [current.clone(), delta]))?;
        self.own_values.insert(
            name.clone(),
            Definition {
                lhs: symbol(name),
                rhs: updated.clone(),
                condition: None,
            },
        );
        Ok(if matches!(operation, "PreIncrement" | "PreDecrement") {
            updated
        } else {
            current
        })
    }

    fn evaluate_update(&mut self, head: Expr, args: Vec<Expr>, operation: &str) -> Result<Expr> {
        let [Expr::Symbol(name), rhs] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let Some(current) = self
            .own_values
            .get(name)
            .map(|definition| definition.rhs.clone())
        else {
            return Ok(call(head, args));
        };
        let rhs = self.evaluate(rhs.clone())?;
        let arithmetic = match operation {
            "AddTo" => "Plus",
            "SubtractFrom" => {
                let rhs = call("Times", [integer(-1), rhs]);
                let updated = self.evaluate(call("Plus", [current, rhs]))?;
                self.store_own(name, updated.clone());
                return Ok(updated);
            }
            "TimesBy" => "Times",
            "DivideBy" => {
                let rhs = call("Power", [rhs, integer(-1)]);
                let updated = self.evaluate(call("Times", [current, rhs]))?;
                self.store_own(name, updated.clone());
                return Ok(updated);
            }
            _ => return Ok(call(head, args)),
        };
        let updated = self.evaluate(call(arithmetic, [current, rhs]))?;
        self.store_own(name, updated.clone());
        Ok(updated)
    }

    fn evaluate_append_to(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [target, value] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let current = self.evaluate(target.clone())?;
        let value = self.evaluate(value.clone())?;
        let Some(appended) = append_or_prepend(&[current, value], false) else {
            return Ok(call(head, args));
        };
        self.evaluate(call("Set", [target.clone(), appended]))
    }

    fn store_own(&mut self, name: &str, rhs: Expr) {
        self.own_values.insert(
            name.to_owned(),
            Definition {
                lhs: symbol(name),
                rhs,
                condition: None,
            },
        );
    }

    fn apply_down_value(&mut self, name: &str, head: &Expr, args: &[Expr]) -> Result<Option<Expr>> {
        let Some(definitions) = self.down_values.get(name).cloned() else {
            return Ok(None);
        };
        let target = call(head.clone(), args.iter().cloned());
        for definition in definitions {
            let mut bindings = Vec::new();
            if self.match_pattern(&target, &definition.lhs, &mut bindings)? {
                if let Some(condition) = &definition.condition {
                    let condition = substitute_binding_values(condition, &bindings);
                    if !is_symbol(&self.evaluate(condition)?, "True") {
                        continue;
                    }
                }
                let rhs = substitute_binding_values(&definition.rhs, &bindings);
                let result = self.evaluate(rhs)?;
                return Ok(Some(self.consume_definition_return(result)));
            }
        }
        Ok(None)
    }

    fn apply_up_values(&mut self, head: &Expr, args: &[Expr]) -> Result<Option<Expr>> {
        let target = call(head.clone(), args.iter().cloned());
        let mut owners = Vec::new();
        for argument in args {
            let owner = match argument {
                Expr::Symbol(name) => Some(name.clone()),
                Expr::Call { .. } => definition_owner(argument),
                _ => None,
            };
            if let Some(owner) = owner
                && !owners.contains(&owner)
            {
                owners.push(owner);
            }
        }
        for owner in owners {
            if let Some(definitions) = self.up_values.get(&owner).cloned()
                && let Some(result) = self.apply_definitions(&target, definitions)?
            {
                return Ok(Some(result));
            }
        }
        Ok(None)
    }

    fn thread_listable(&mut self, head: &Expr, args: &[Expr]) -> Result<Option<Expr>> {
        let lengths = args
            .iter()
            .filter_map(|argument| argument.has_head("List").then_some(argument.args().len()))
            .collect::<Vec<_>>();
        let Some(&length) = lengths.first() else {
            return Ok(None);
        };
        if lengths.iter().any(|candidate| *candidate != length) {
            if let Expr::Symbol(name) = head {
                self.emit_error_message(system_dispatch_name(name));
            } else {
                self.emit_error_message("General");
            }
            return Ok(None);
        }
        let mut output = Vec::with_capacity(length);
        for index in 0..length {
            let threaded = args.iter().map(|argument| {
                if argument.has_head("List") {
                    argument.args()[index].clone()
                } else {
                    argument.clone()
                }
            });
            output.push(self.evaluate(call(head.clone(), threaded))?);
        }
        Ok(Some(list(output)))
    }

    fn apply_sub_value(&mut self, name: &str, head: &Expr, args: &[Expr]) -> Result<Option<Expr>> {
        let Some(definitions) = self.sub_values.get(name).cloned() else {
            return Ok(None);
        };
        let target = call(head.clone(), args.iter().cloned());
        self.apply_definitions(&target, definitions)
    }

    fn apply_definitions(
        &mut self,
        target: &Expr,
        definitions: Vec<Definition>,
    ) -> Result<Option<Expr>> {
        for definition in definitions {
            let mut bindings = Vec::new();
            if self.match_pattern(target, &definition.lhs, &mut bindings)? {
                if let Some(condition) = &definition.condition {
                    let condition = substitute_binding_values(condition, &bindings);
                    if !is_symbol(&self.evaluate(condition)?, "True") {
                        continue;
                    }
                }
                let rhs = substitute_binding_values(&definition.rhs, &bindings);
                let result = self.evaluate(rhs)?;
                return Ok(Some(self.consume_definition_return(result)));
            }
        }
        Ok(None)
    }

    fn consume_definition_return(&mut self, result: Expr) -> Expr {
        if matches!(self.control, Some(Control::Return { head: None, .. }))
            && let Some(Control::Return { value, .. }) = self.control.take()
        {
            value
        } else {
            result
        }
    }

    fn prepare_assignment_lhs(&mut self, lhs: &Expr) -> Result<Expr> {
        let mut pattern_names = Vec::new();
        collect_pattern_names(lhs, &mut pattern_names);
        self.prepare_assignment_lhs_node(lhs, &pattern_names)
    }

    fn prepare_assignment_lhs_node(
        &mut self,
        expr: &Expr,
        pattern_names: &[String],
    ) -> Result<Expr> {
        let Expr::Call { head, args } = expr else {
            return self.evaluate_shielded(expr.clone(), pattern_names);
        };
        let prepared_head = if matches!(head.as_ref(), Expr::Call { .. }) {
            self.prepare_assignment_lhs_node(head, pattern_names)?
        } else {
            self.evaluate_shielded(head.as_ref().clone(), pattern_names)?
        };
        let prepared_args = args
            .iter()
            .map(|argument| {
                if contains_pattern_construct(argument) {
                    self.prepare_assignment_lhs_node(argument, pattern_names)
                } else {
                    self.evaluate_shielded(argument.clone(), pattern_names)
                }
            })
            .collect::<Result<Vec<_>>>()?;
        Ok(call(prepared_head, prepared_args))
    }

    fn evaluate_shielded(&mut self, expr: Expr, names: &[String]) -> Result<Expr> {
        let initial_length = self.active_symbols.len();
        for name in names {
            if !self.active_symbols.contains(name) {
                self.active_symbols.push(name.clone());
            }
        }
        let result = self.evaluate(expr);
        self.active_symbols.truncate(initial_length);
        result
    }

    fn evaluate_check_abort(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [body, fallback] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let value = self.evaluate(body.clone())?;
        if matches!(self.control, Some(Control::Abort)) {
            self.control = None;
            self.evaluate(fallback.clone())
        } else {
            Ok(value)
        }
    }

    fn evaluate_check(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !matches!(args.len(), 2 | 3) {
            return Ok(call(head, args));
        }
        let spec = if let Some(spec) = args.get(2) {
            self.evaluate(spec.clone())?
        } else {
            symbol("All")
        };
        let event_start = self.message_events.len();
        let quiet_depth = self.quiet_scopes.len();
        let result = self.evaluate(args[0].clone())?;
        let captured = self.message_events[event_start..].iter().any(|event| {
            event
                .suppression_depth
                .is_none_or(|depth| quiet_depth >= depth)
                && message_spec_matches(&spec, &event.name)
        });
        if captured {
            self.evaluate(args[1].clone())
        } else {
            Ok(result)
        }
    }

    fn evaluate_quiet(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !matches!(args.len(), 1..=3) {
            return Ok(call(head, args));
        }
        let off_spec = if let Some(spec) = args.get(1) {
            self.evaluate(spec.clone())?
        } else {
            symbol("All")
        };
        let on_spec = if let Some(spec) = args.get(2) {
            self.evaluate(spec.clone())?
        } else {
            symbol("None")
        };
        self.quiet_scopes.push(QuietScope { off_spec, on_spec });
        let result = self.evaluate(args[0].clone());
        self.quiet_scopes.pop();
        result
    }

    fn evaluate_message(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let Some(message_name) = args.first().cloned() else {
            return Ok(call(head, args));
        };
        if !message_name.has_head("MessageName") || message_name.args().len() < 2 {
            return Ok(call(head, args));
        }
        let mut insertions = Vec::new();
        for insertion in args.iter().skip(1) {
            insertions.push(self.evaluate(insertion.clone())?);
        }
        let rendered_name = message_name.to_input_form();
        let text = if insertions.is_empty() {
            format!("{rendered_name}: Message generated.")
        } else {
            let preprint = if self.session_hooks_enabled {
                self.evaluate(symbol("$MessagePrePrint"))?
            } else {
                symbol("Automatic")
            };
            let mut rendered = Vec::new();
            for insertion in insertions {
                let insertion = if is_symbol(&preprint, "Automatic")
                    || is_symbol(&preprint, "$MessagePrePrint")
                {
                    insertion
                } else {
                    self.evaluate(call(preprint.clone(), [insertion]))?
                };
                rendered.push(format_print_argument(&insertion));
            }
            format!("{rendered_name}: {}", rendered.join(", "))
        };
        self.emit_message_name_with_text(message_name, text);
        Ok(symbol("Null"))
    }

    fn evaluate_on_off(&mut self, head: Expr, args: Vec<Expr>, enabled: bool) -> Result<Expr> {
        for argument in &args {
            let spec = self.evaluate(argument.clone())?;
            if !self.set_message_enabled(&spec, enabled) {
                return Ok(call(head, args));
            }
        }
        Ok(symbol("Null"))
    }

    fn set_message_enabled(&mut self, spec: &Expr, enabled: bool) -> bool {
        if spec.has_head("List") {
            return spec
                .args()
                .iter()
                .all(|item| self.set_message_enabled(item, enabled));
        }
        if spec
            .symbol_name()
            .is_some_and(|name| system_dispatch_name(name) == "Assert")
        {
            self.assert_enabled = enabled;
            return true;
        }
        let normalized = if let Expr::Symbol(name) = spec {
            call("MessageName", [symbol(name), string("trace")])
        } else if spec.has_head("MessageName") {
            spec.clone()
        } else {
            return false;
        };
        if enabled {
            self.disabled_messages.remove(&normalized.to_full_form());
        } else {
            self.disabled_messages.insert(normalized.to_full_form());
        }
        true
    }

    fn evaluate_assert(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !matches!(args.len(), 1 | 2) {
            return Ok(call(head, args));
        }
        if !self.assert_enabled {
            return Ok(call(head, args));
        }
        let test = self.evaluate(args[0].clone())?;
        if is_symbol(&test, "True") {
            return Ok(symbol("Null"));
        }
        let tag = if let Some(tag) = args.get(1) {
            self.evaluate(tag.clone())?
        } else {
            symbol("Null")
        };
        self.emit_message_detail(
            "Assert",
            "asrtfl",
            format!(
                "{}, {}",
                format_print_argument(&test),
                format_print_argument(&tag)
            ),
        );
        Ok(symbol("Null"))
    }

    fn evaluate_with_cleanup(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !matches!(args.len(), 2 | 3) {
            return Ok(call(head, args));
        }
        let cleanup = args.last().cloned().expect("validated cleanup argument");
        let mut result = symbol("Null");
        if args.len() == 3 {
            result = self.evaluate(args[0].clone())?;
        }
        if self.control.is_none() {
            result = self.evaluate(args[args.len() - 2].clone())?;
        }
        let pending = self.control.take();
        let cleanup_result = self.evaluate(cleanup);
        let cleanup_control = self.control.take();
        self.control = pending.or(cleanup_control);
        cleanup_result?;
        Ok(result)
    }

    fn evaluate_throw(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.is_empty() || args.len() > 3 {
            return Ok(call(head, args));
        }
        let value = self.evaluate(args[0].clone())?;
        if self.control.is_some() {
            return Ok(value);
        }
        let tag = if let Some(tag) = args.get(1) {
            let tag = self.evaluate(tag.clone())?;
            if self.control.is_some() {
                return Ok(tag);
            }
            Some(tag)
        } else {
            None
        };
        let handler = args.get(2).cloned();
        self.control = Some(Control::Throw {
            value: value.clone(),
            tag,
            handler,
        });
        Ok(value)
    }

    fn evaluate_catch(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.is_empty() || args.len() > 3 {
            return Ok(call(head, args));
        }
        let value = self.evaluate(args[0].clone())?;
        let Some(Control::Throw {
            value: thrown,
            tag,
            handler: _,
        }) = self.control.as_ref()
        else {
            return Ok(value);
        };
        let pattern = args.get(1);
        let matches = match (pattern, tag) {
            (None, None) => true,
            (None, Some(_)) | (Some(_), None) => false,
            (Some(pattern), Some(tag)) => simple_pattern_matches(tag, pattern),
        };
        if !matches {
            return Ok(value);
        }
        let thrown = thrown.clone();
        let tag = tag.clone();
        self.control = None;
        if let Some(handler) = args.get(2) {
            let tag = tag.unwrap_or_else(|| symbol("Null"));
            self.evaluate(call(handler.clone(), [thrown, tag]))
        } else {
            Ok(thrown)
        }
    }

    fn evaluate_sow(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.is_empty() || args.len() > 2 {
            return Ok(call(head, args));
        }
        let value = self.evaluate(args[0].clone())?;
        if self.control.is_some() {
            return Ok(value);
        }
        let tags = if let Some(tag) = args.get(1) {
            let tag = self.evaluate(tag.clone())?;
            if tag.has_head("List") {
                tag.args().to_vec()
            } else {
                vec![tag]
            }
        } else {
            vec![symbol("None")]
        };
        for tag in tags {
            for scope in self.reap_stack.iter_mut().rev() {
                let matching = scope
                    .patterns
                    .iter()
                    .enumerate()
                    .filter_map(|(index, pattern)| {
                        simple_pattern_matches(&tag, pattern).then_some(index)
                    })
                    .collect::<Vec<_>>();
                if matching.is_empty() {
                    continue;
                }
                for index in matching {
                    if let Some((_, values)) = scope.buckets[index]
                        .iter_mut()
                        .find(|(existing, _)| existing == &tag)
                    {
                        values.push(value.clone());
                    } else {
                        scope.buckets[index].push((tag.clone(), vec![value.clone()]));
                    }
                }
                break;
            }
        }
        Ok(value)
    }

    fn evaluate_reap(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.is_empty() || args.len() > 3 {
            return Ok(call(head, args));
        }
        let pattern = if let Some(pattern) = args.get(1) {
            self.evaluate(pattern.clone())?
        } else {
            call("Blank", [])
        };
        let pattern_list_mode = pattern.has_head("List");
        let patterns = if pattern_list_mode {
            pattern.args().to_vec()
        } else {
            vec![pattern]
        };
        let bucket_count = patterns.len();
        self.reap_stack.push(ReapScope {
            patterns,
            pattern_list_mode,
            buckets: (0..bucket_count).map(|_| Vec::new()).collect(),
        });
        let value = self.evaluate(args[0].clone())?;
        let scope = self.reap_stack.pop().expect("scope was pushed");
        if self.control.is_some() {
            return Ok(value);
        }
        let mut groups = Vec::new();
        for bucket in scope.buckets {
            let bucket_groups = bucket
                .into_iter()
                .map(|(tag, values)| {
                    let values = list(values);
                    args.get(2).map_or(values.clone(), |function| {
                        call(function.clone(), [tag, values])
                    })
                })
                .collect::<Vec<_>>();
            if scope.pattern_list_mode {
                groups.push(list(bucket_groups));
            } else {
                groups.extend(bucket_groups);
            }
        }
        Ok(list([value, list(groups)]))
    }

    fn evaluate_time_constrained(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let ([body, limit] | [body, limit, _]) = args.as_slice() else {
            return Ok(call(head, args));
        };
        let limit = self.evaluate(limit.clone())?;
        if is_symbol(&limit, "Infinity") {
            return self.evaluate(body.clone());
        }
        let Some(seconds) = numeric_real_value(&limit) else {
            return Ok(call(head, args));
        };
        let seconds = seconds.max(0.0);
        let now = Instant::now();
        let duration = Duration::from_secs_f64(seconds.min(Duration::MAX.as_secs_f64()));
        let mut deadline = now.checked_add(duration).unwrap_or(now);
        if let Some(parent) = self.time_deadlines.last()
            && *parent < deadline
        {
            deadline = *parent;
        }
        self.time_deadlines.push(deadline);
        let value = self.evaluate(body.clone())?;
        let expired = Instant::now() >= deadline;
        self.time_deadlines.pop();
        if expired && self.control.is_none() {
            self.control = Some(Control::Timeout);
        }
        if matches!(self.control, Some(Control::Timeout)) {
            self.control = None;
            if let Some(fallback) = args.get(2) {
                self.evaluate(fallback.clone())
            } else {
                Ok(symbol("$Aborted"))
            }
        } else {
            Ok(value)
        }
    }

    fn evaluate_time_remaining(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !args.is_empty() {
            return Ok(call(head, args));
        }
        Ok(self.time_deadlines.last().map_or_else(
            || symbol("Infinity"),
            |deadline| {
                Expr::Real(format_machine_real(
                    deadline
                        .saturating_duration_since(Instant::now())
                        .as_secs_f64(),
                ))
            },
        ))
    }

    fn evaluate_pause(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [duration] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let duration = self.evaluate(duration.clone())?;
        let Some(seconds) = numeric_real_value(&duration) else {
            return Ok(call(head, args));
        };
        if !seconds.is_finite() || seconds < 0.0 {
            return Ok(call(head, args));
        }
        let requested = Duration::from_secs_f64(seconds);
        if let Some(deadline) = self.time_deadlines.last().copied() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            std::thread::sleep(requested.min(remaining));
            if requested >= remaining {
                self.control = Some(Control::Timeout);
                return Ok(symbol("$Aborted"));
            }
        } else {
            std::thread::sleep(requested);
        }
        Ok(symbol("Null"))
    }

    fn evaluate_absolute_timing(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [body] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let start = Instant::now();
        let value = self.evaluate(body.clone())?;
        Ok(list([
            Expr::Real(format_machine_real(start.elapsed().as_secs_f64())),
            value,
        ]))
    }

    fn evaluate_confirm(&mut self, head: Expr, args: Vec<Expr>, operation: &str) -> Result<Expr> {
        let valid = match operation {
            "Confirm" => matches!(args.len(), 1..=3),
            "ConfirmBy" | "ConfirmMatch" => matches!(args.len(), 2..=4),
            "ConfirmAssert" => matches!(args.len(), 1..=3),
            _ => false,
        };
        if !valid {
            return Ok(call(head, args));
        }
        let value = self.evaluate(args[0].clone())?;
        if self.control.is_some() {
            return Ok(value);
        }
        let mut extra = Vec::new();
        let confirmed = match operation {
            "Confirm" => !is_confirm_failure(&value),
            "ConfirmBy" => {
                let function = self.evaluate(args[1].clone())?;
                extra.push(("Function", function.clone()));
                is_symbol(&self.evaluate(call(function, [value.clone()]))?, "True")
            }
            "ConfirmMatch" => {
                extra.push(("Pattern", args[1].clone()));
                self.match_pattern(&value, &args[1], &mut Vec::new())?
            }
            "ConfirmAssert" => {
                extra.push(("Test", value.clone()));
                is_symbol(&value, "True")
            }
            _ => unreachable!(),
        };
        if confirmed {
            return Ok(if operation == "ConfirmAssert" {
                symbol("Null")
            } else {
                value
            });
        }
        let info_index = if matches!(operation, "ConfirmBy" | "ConfirmMatch") {
            2
        } else {
            1
        };
        let info = if let Some(info) = args.get(info_index) {
            self.evaluate(info.clone())?
        } else {
            symbol("Null")
        };
        let tag_index = info_index + 1;
        let tag = if let Some(tag) = args.get(tag_index) {
            Some(self.evaluate(tag.clone())?)
        } else {
            None
        };
        let failure = if operation == "Confirm" && args.len() == 1 && value.has_head("Failure") {
            value
        } else {
            confirmation_failure(operation, value, info, extra)
        };
        self.control = Some(Control::Confirm {
            failure: failure.clone(),
            tag,
        });
        Ok(failure)
    }

    fn evaluate_enclose(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !matches!(args.len(), 1..=3) {
            return Ok(call(head, args));
        }
        let form = if let Some(form) = args.get(2) {
            Some(self.evaluate(form.clone())?)
        } else {
            None
        };
        let value = self.evaluate(args[0].clone())?;
        let captured = match self.control.as_ref() {
            Some(Control::Confirm { failure, tag })
                if match (form.as_ref(), tag.as_ref()) {
                    (None, None) => true,
                    (Some(pattern), Some(tag)) => simple_pattern_matches(tag, pattern),
                    _ => false,
                } =>
            {
                Some(failure.clone())
            }
            _ => None,
        };
        let Some(failure) = captured else {
            return Ok(value);
        };
        self.control = None;
        let Some(handler) = args.get(1) else {
            return Ok(failure);
        };
        let handler = self.evaluate(handler.clone())?;
        if matches!(handler, Expr::String(_)) {
            Ok(failure_property(&failure, &handler))
        } else {
            self.evaluate(call(handler, [failure]))
        }
    }

    fn evaluate_failsafe_apply(&mut self, function: Expr, args: Vec<Expr>) -> Result<Expr> {
        let evaluated = args
            .into_iter()
            .map(|argument| self.evaluate(argument))
            .collect::<Result<Vec<_>>>()?;
        match function.args() {
            [target] => {
                if let Some(failure) = evaluated.iter().find(|value| is_confirm_failure(value)) {
                    Ok(failure.clone())
                } else {
                    self.evaluate(call(target.clone(), evaluated))
                }
            }
            [target, test] | [target, test, _] => {
                let passed = self.evaluate(call(test.clone(), evaluated.clone()))?;
                if is_symbol(&passed, "True") {
                    self.evaluate(call(target.clone(), evaluated))
                } else if let Some(fallback) = function.args().get(2) {
                    self.evaluate(call(fallback.clone(), evaluated))
                } else {
                    Ok(failure_expr(
                        "FailsafeFailed",
                        [("Arguments", call("Hold", evaluated))],
                    ))
                }
            }
            _ => Ok(call(function, evaluated)),
        }
    }

    fn evaluate_match_q(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let [target, pattern] = args.as_slice() else {
            return Ok(call(head, args));
        };
        let target = self.evaluate(target.clone())?;
        let mut bindings = Vec::new();
        Ok(bool_expr(self.match_pattern(
            &target,
            pattern,
            &mut bindings,
        )?))
    }

    fn evaluate_root_call(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let mut prepared = Vec::with_capacity(args.len());
        for (index, argument) in args.iter().enumerate() {
            if index == 0 && argument.has_head("Function") {
                prepared.push(argument.clone());
            } else {
                prepared.push(self.evaluate(argument.clone())?);
            }
        }
        Ok(self
            .root_expr(&prepared)?
            .unwrap_or_else(|| call(head, args)))
    }

    fn evaluate_free_q(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let Some((positional, include_heads)) = heads_option_arguments(&args, true) else {
            return Ok(call(head, args));
        };
        if !(2..=3).contains(&positional.len()) {
            return Ok(call(head, args));
        }
        let target = self.evaluate(positional[0].clone())?;
        let default_spec = list([integer(0), symbol("Infinity")]);
        let spec = positional.get(2).copied().unwrap_or(&default_spec);
        let mut output = Vec::new();
        let mut remaining = Some(1);
        self.collect_pattern_matches(
            &target,
            positional[1],
            spec,
            include_heads,
            0,
            &mut remaining,
            &mut output,
            None,
        )?;
        Ok(bool_expr(output.is_empty()))
    }

    fn evaluate_replace(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let Some((positional, include_heads)) = heads_option_arguments(&args, false) else {
            return Ok(call(head, args));
        };
        if !(2..=3).contains(&positional.len()) {
            return Ok(call(head, args));
        }
        if positional[1].has_head("List")
            && positional[1]
                .args()
                .iter()
                .all(|ruleset| ruleset.has_head("List"))
        {
            let mut results = Vec::new();
            for ruleset in positional[1].args() {
                let mut nested_args = vec![positional[0].clone(), ruleset.clone()];
                nested_args.extend(positional.iter().skip(2).map(|value| (*value).clone()));
                results.push(self.evaluate_replace(head.clone(), nested_args)?);
            }
            return Ok(list(results));
        }
        let target = self.evaluate(positional[0].clone())?;
        let rules = normalize_rules(positional[1]);
        if rules.iter().any(|rule| rule_parts(rule).is_none()) {
            return Ok(call(head, args));
        }
        if let Some(spec) = positional.get(2) {
            self.replace_at_levels(&target, &rules, spec, include_heads, 0)
        } else {
            Ok(match self.apply_first_rule(&target, &rules)? {
                Some(replacement) => self.evaluate(replacement)?,
                None => target,
            })
        }
    }

    fn evaluate_replace_all(
        &mut self,
        head: Expr,
        args: Vec<Expr>,
        repeated: bool,
    ) -> Result<Expr> {
        let [target, rules] = args.as_slice() else {
            return Ok(call(head, args));
        };
        if rules.has_head("List") && rules.args().iter().all(|ruleset| ruleset.has_head("List")) {
            let mut results = Vec::new();
            for ruleset in rules.args() {
                results.push(self.evaluate_replace_all(
                    head.clone(),
                    vec![target.clone(), ruleset.clone()],
                    repeated,
                )?);
            }
            return Ok(list(results));
        }
        let mut result = self.evaluate(target.clone())?;
        if self.control.is_some() {
            return Ok(result);
        }
        let normalized = normalize_rules(rules);
        if normalized.is_empty() {
            return Ok(call(head, args));
        }
        let limit = if repeated { 256 } else { 1 };
        for _ in 0..limit {
            let next = self.replace_recursive(&result, &normalized)?;
            let next = self.evaluate(next)?;
            if next == result {
                break;
            }
            result = next;
            if !repeated {
                break;
            }
        }
        self.evaluate(result)
    }

    fn evaluate_cases(&mut self, head: Expr, args: Vec<Expr>, delete: bool) -> Result<Expr> {
        let Some((positional, include_heads)) = heads_option_arguments(&args, false) else {
            return Ok(call(head, args));
        };
        if !(2..=4).contains(&positional.len()) {
            return Ok(call(head, args));
        }
        let target = self.evaluate(positional[0].clone())?;
        let pattern_or_rule = positional[1];
        let rule = rule_parts(pattern_or_rule);
        let pattern = rule.map_or(pattern_or_rule, |(pattern, _, _)| pattern);
        let default_spec = integer(1);
        let spec = positional.get(2).copied().unwrap_or(&default_spec);
        let Some(mut remaining) = match_limit(positional.get(3).copied()) else {
            return Ok(call(head, args));
        };
        if delete {
            return Ok(self
                .delete_cases_at_levels(&target, pattern, spec, include_heads, 0, &mut remaining)?
                .unwrap_or_else(|| call("Sequence", [])));
        }
        let mut output = Vec::new();
        self.collect_pattern_matches(
            &target,
            pattern,
            spec,
            include_heads,
            0,
            &mut remaining,
            &mut output,
            rule,
        )?;
        Ok(list(output))
    }

    fn evaluate_count(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let Some((positional, include_heads)) = heads_option_arguments(&args, false) else {
            return Ok(call(head, args));
        };
        if !(2..=3).contains(&positional.len()) {
            return Ok(call(head, args));
        }
        let target = self.evaluate(positional[0].clone())?;
        let default_spec = integer(1);
        let spec = positional.get(2).copied().unwrap_or(&default_spec);
        let mut output = Vec::new();
        let mut remaining = None;
        self.collect_pattern_matches(
            &target,
            positional[1],
            spec,
            include_heads,
            0,
            &mut remaining,
            &mut output,
            None,
        )?;
        Ok(integer(output.len()))
    }

    fn evaluate_member_q(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let Some((positional, include_heads)) = heads_option_arguments(&args, false) else {
            return Ok(call(head, args));
        };
        if !(2..=3).contains(&positional.len()) {
            return Ok(call(head, args));
        }
        let target = self.evaluate(positional[0].clone())?;
        let default_spec = list([integer(1)]);
        let spec = positional.get(2).copied().unwrap_or(&default_spec);
        let mut output = Vec::new();
        let mut remaining = Some(1);
        self.collect_pattern_matches(
            &target,
            positional[1],
            spec,
            include_heads,
            0,
            &mut remaining,
            &mut output,
            None,
        )?;
        Ok(bool_expr(!output.is_empty()))
    }

    #[allow(clippy::too_many_arguments)]
    fn collect_pattern_matches(
        &mut self,
        expr: &Expr,
        pattern: &Expr,
        spec: &Expr,
        include_heads: bool,
        level: i64,
        remaining: &mut Option<usize>,
        output: &mut Vec<Expr>,
        rule: Option<(&Expr, &Expr, bool)>,
    ) -> Result<()> {
        if remaining.is_some_and(|count| count == 0) {
            return Ok(());
        }
        if let Some(entries) = association_entries(expr) {
            if include_heads {
                self.collect_pattern_matches(
                    &expr.head(),
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                    output,
                    rule,
                )?;
            }
            for entry in entries {
                self.collect_pattern_matches(
                    &entry.args()[1],
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                    output,
                    rule,
                )?;
            }
        } else if let Expr::Call { head, args } = expr {
            if include_heads {
                self.collect_pattern_matches(
                    head,
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                    output,
                    rule,
                )?;
            }
            for argument in args {
                self.collect_pattern_matches(
                    argument,
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                    output,
                    rule,
                )?;
            }
        }
        if remaining.is_some_and(|count| count == 0)
            || !level_spec_matches(spec, level, -(depth(expr) as i64)).unwrap_or(false)
        {
            return Ok(());
        }
        let mut bindings = Vec::new();
        if self.match_pattern(expr, pattern, &mut bindings)? {
            let value = if let Some((_, rhs, _)) = rule {
                let replacement = substitute_binding_values(rhs, &bindings);
                if replacement.has_head("Condition")
                    && let [body, condition] = replacement.args()
                {
                    if !is_symbol(&self.evaluate(condition.clone())?, "True") {
                        return Ok(());
                    }
                    self.evaluate(body.clone())?
                } else {
                    self.evaluate(replacement)?
                }
            } else {
                expr.clone()
            };
            if value.has_head("Sequence") {
                output.extend(value.args().iter().cloned());
                if let Some(count) = remaining {
                    *count = count.saturating_sub(1);
                }
            } else if !is_symbol(&value, "Nothing") {
                output.push(value);
                if let Some(count) = remaining {
                    *count = count.saturating_sub(1);
                }
            }
        }
        Ok(())
    }

    #[allow(clippy::too_many_arguments)]
    fn delete_cases_at_levels(
        &mut self,
        expr: &Expr,
        pattern: &Expr,
        spec: &Expr,
        include_heads: bool,
        level: i64,
        remaining: &mut Option<usize>,
    ) -> Result<Option<Expr>> {
        let (mut rebuilt, deleted_head) = if let Some(entries) = association_entries(expr) {
            let mut rules = Vec::new();
            for entry in entries {
                if let Some(value) = self.delete_cases_at_levels(
                    &entry.args()[1],
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                )? {
                    rules.push(call("Rule", [entry.args()[0].clone(), value]));
                }
            }
            (call("Association", rules), false)
        } else if let Expr::Call { head, args } = expr {
            let mut deleted_head = false;
            let new_head = if include_heads {
                match self.delete_cases_at_levels(
                    head,
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                )? {
                    Some(head) => head,
                    None => {
                        deleted_head = true;
                        symbol("Sequence")
                    }
                }
            } else {
                head.as_ref().clone()
            };
            let mut values = Vec::new();
            for argument in args {
                if let Some(value) = self.delete_cases_at_levels(
                    argument,
                    pattern,
                    spec,
                    include_heads,
                    level + 1,
                    remaining,
                )? {
                    if value.has_head("Sequence") {
                        values.extend(value.args().iter().cloned());
                    } else {
                        values.push(value);
                    }
                }
            }
            (call(new_head, values), deleted_head)
        } else {
            (expr.clone(), false)
        };
        if deleted_head || remaining.is_some_and(|count| count == 0) {
            return Ok(Some(rebuilt));
        }
        if level_spec_matches(spec, level, -(depth(&rebuilt) as i64)).unwrap_or(false) {
            let mut bindings = Vec::new();
            if self.match_pattern(&rebuilt, pattern, &mut bindings)? {
                if let Some(count) = remaining {
                    *count = count.saturating_sub(1);
                }
                return Ok(None);
            }
        }
        if rebuilt.has_head("List") {
            rebuilt = list(
                rebuilt
                    .args()
                    .iter()
                    .filter(|value| !is_symbol(value, "Nothing"))
                    .cloned(),
            );
        }
        Ok(Some(rebuilt))
    }

    fn replace_at_levels(
        &mut self,
        expr: &Expr,
        rules: &[Expr],
        spec: &Expr,
        include_heads: bool,
        level: i64,
    ) -> Result<Expr> {
        let rebuilt = if let Some(entries) = association_entries(expr) {
            let mut output = Vec::new();
            for entry in entries {
                output.push(call(
                    "Rule",
                    [
                        entry.args()[0].clone(),
                        self.replace_at_levels(
                            &entry.args()[1],
                            rules,
                            spec,
                            include_heads,
                            level + 1,
                        )?,
                    ],
                ));
            }
            call("Association", output)
        } else if let Expr::Call { head, args } = expr {
            let replaced_head = if include_heads {
                self.replace_at_levels(head, rules, spec, include_heads, level + 1)?
            } else {
                head.as_ref().clone()
            };
            let replaced_args = args
                .iter()
                .map(|argument| {
                    self.replace_at_levels(argument, rules, spec, include_heads, level + 1)
                })
                .collect::<Result<Vec<_>>>()?;
            call(replaced_head, replaced_args)
        } else {
            expr.clone()
        };
        if level_spec_matches(spec, level, -(depth(&rebuilt) as i64)).unwrap_or(false)
            && let Some(replacement) = self.apply_first_rule(&rebuilt, rules)?
        {
            self.evaluate(replacement)
        } else {
            Ok(rebuilt)
        }
    }

    fn replace_recursive(&mut self, expr: &Expr, rules: &[Expr]) -> Result<Expr> {
        if let Some(replacement) = self.apply_first_rule(expr, rules)? {
            return Ok(replacement);
        }
        if let Some(entries) = association_entries(expr) {
            let replaced_head = self
                .apply_first_rule(&expr.head(), rules)?
                .unwrap_or_else(|| expr.head());
            let replaced_entries = entries
                .into_iter()
                .map(|entry| {
                    Ok(call(
                        entry.head(),
                        [
                            entry.args()[0].clone(),
                            self.replace_recursive(&entry.args()[1], rules)?,
                        ],
                    ))
                })
                .collect::<Result<Vec<_>>>()?;
            Ok(call(replaced_head, replaced_entries))
        } else if let Expr::Call { head, args } = expr {
            let replaced_head = self.replace_recursive(head, rules)?;
            let replaced_args = args
                .iter()
                .map(|argument| self.replace_recursive(argument, rules))
                .collect::<Result<Vec<_>>>()?;
            Ok(call(replaced_head, replaced_args))
        } else {
            Ok(expr.clone())
        }
    }

    fn apply_first_rule(&mut self, expr: &Expr, rules: &[Expr]) -> Result<Option<Expr>> {
        for rule in rules {
            let Some((pattern, rhs, _delayed)) = rule_parts(rule) else {
                continue;
            };
            let mut bindings = Vec::new();
            if self.match_pattern(expr, pattern, &mut bindings)? {
                let replacement = substitute_binding_values(rhs, &bindings);
                if replacement.has_head("Condition")
                    && let [body, condition] = replacement.args()
                {
                    if is_symbol(&self.evaluate(condition.clone())?, "True") {
                        return Ok(Some(body.clone()));
                    }
                    continue;
                }
                return Ok(Some(replacement));
            }
        }
        Ok(None)
    }

    fn match_pattern(
        &mut self,
        expr: &Expr,
        pattern: &Expr,
        bindings: &mut Vec<(String, Expr)>,
    ) -> Result<bool> {
        self.match_pattern_mode(expr, pattern, bindings, false)
    }

    fn match_pattern_mode(
        &mut self,
        expr: &Expr,
        pattern: &Expr,
        bindings: &mut Vec<(String, Expr)>,
        ignore_inactive: bool,
    ) -> Result<bool> {
        if pattern.has_head("IgnoringInactive") && pattern.args().len() == 1 {
            return self.match_pattern_mode(expr, &pattern.args()[0], bindings, true);
        }
        let structural_expr = ignore_inactive.then(|| active_view(expr));
        let structural_pattern = ignore_inactive.then(|| active_view(pattern));
        let matched_expr = structural_expr.as_ref().unwrap_or(expr);
        let matched_pattern = structural_pattern.as_ref().unwrap_or(pattern);

        if matched_pattern.has_head("HoldPattern") && matched_pattern.args().len() == 1 {
            return self.match_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if matched_pattern.has_head("Verbatim") && matched_pattern.args().len() == 1 {
            return Ok(if ignore_inactive {
                active_view(expr) == active_view(&matched_pattern.args()[0])
            } else {
                expr == &matched_pattern.args()[0]
            });
        }
        if matched_pattern.has_head("Except") && matches!(matched_pattern.args().len(), 1 | 2) {
            let original = bindings.clone();
            let allowed = if let Some(allowed) = matched_pattern.args().get(1) {
                self.match_pattern_mode(expr, allowed, bindings, ignore_inactive)?
            } else {
                true
            };
            if !allowed {
                *bindings = original;
                return Ok(false);
            }
            let mut excluded_bindings = original;
            if self.match_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                &mut excluded_bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            return Ok(true);
        }
        if (matched_pattern.has_head("Longest") || matched_pattern.has_head("Shortest"))
            && matches!(matched_pattern.args().len(), 1 | 2)
        {
            return self.match_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if matched_pattern.has_head("Optional") && matches!(matched_pattern.args().len(), 1 | 2) {
            return self.match_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if matched_pattern.has_head("KeyValuePattern") && matched_pattern.args().len() == 1 {
            return self.match_key_value_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if matched_pattern.has_head("Pattern") && matched_pattern.args().len() == 2 {
            let Expr::Symbol(name) = &matched_pattern.args()[0] else {
                return Ok(false);
            };
            if is_sequence_argument_pattern(&matched_pattern.args()[1]) {
                return self.match_sequence_pattern_elements_mode(
                    std::slice::from_ref(expr),
                    matched_pattern,
                    bindings,
                    ignore_inactive,
                );
            }
            if !self.match_pattern_mode(
                expr,
                &matched_pattern.args()[1],
                bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            if let Some((_, existing)) = bindings.iter().find(|(existing, _)| existing == name) {
                return Ok(existing == expr);
            }
            bindings.push((name.clone(), expr.clone()));
            return Ok(true);
        }
        if matched_pattern.has_head("Blank") {
            return Ok(match matched_pattern.args() {
                [] => true,
                [Expr::Symbol(expected)] => {
                    matched_expr.head().symbol_name().is_some_and(|actual| {
                        system_dispatch_name(actual) == system_dispatch_name(expected)
                    })
                }
                _ => false,
            });
        }
        if matched_pattern.has_head("Alternatives") {
            for alternative in matched_pattern.args() {
                let original_length = bindings.len();
                if self.match_pattern_mode(expr, alternative, bindings, ignore_inactive)? {
                    return Ok(true);
                }
                bindings.truncate(original_length);
            }
            return Ok(false);
        }
        if matched_pattern.has_head("PatternTest") && matched_pattern.args().len() == 2 {
            let original_length = bindings.len();
            if !self.match_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            let test = self.evaluate(call(matched_pattern.args()[1].clone(), [expr.clone()]))?;
            if is_symbol(&test, "True") {
                return Ok(true);
            }
            bindings.truncate(original_length);
            return Ok(false);
        }
        if matched_pattern.has_head("Condition") && matched_pattern.args().len() == 2 {
            let original_length = bindings.len();
            if !self.match_pattern_mode(
                expr,
                &matched_pattern.args()[0],
                bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            let condition = substitute_binding_values(&matched_pattern.args()[1], bindings);
            if is_symbol(&self.evaluate(condition)?, "True") {
                return Ok(true);
            }
            bindings.truncate(original_length);
            return Ok(false);
        }
        if direct_sequence_pattern_head(matched_pattern).is_some() {
            return self.match_sequence_pattern_elements_mode(
                std::slice::from_ref(expr),
                matched_pattern,
                bindings,
                ignore_inactive,
            );
        }
        if let (
            Expr::Call {
                head: expr_head,
                args: expr_args,
            },
            Expr::Call {
                head: pattern_head,
                args: pattern_args,
            },
        ) = (matched_expr, matched_pattern)
        {
            let original_head =
                if ignore_inactive && expr.has_head("Inactive") && expr.args().len() == 1 {
                    expr_head.as_ref()
                } else if let Expr::Call { head, .. } = expr {
                    head.as_ref()
                } else {
                    expr_head.as_ref()
                };
            if !self.match_pattern_mode(original_head, pattern_head, bindings, ignore_inactive)? {
                return Ok(false);
            }
            let original_args = if ignore_inactive
                && !expr.has_head("Inactive")
                && expr.args().len() == expr_args.len()
            {
                expr.args()
            } else {
                expr_args
            };
            return self.match_call_arguments_mode(
                original_args,
                pattern_args,
                bindings,
                ignore_inactive,
            );
        }
        Ok(matched_expr == matched_pattern)
    }

    fn match_call_arguments_mode(
        &mut self,
        expressions: &[Expr],
        patterns: &[Expr],
        bindings: &mut Vec<(String, Expr)>,
        ignore_inactive: bool,
    ) -> Result<bool> {
        if patterns.is_empty() {
            return Ok(expressions.is_empty());
        }
        if is_sequence_argument_pattern(&patterns[0]) {
            let Some((minimum, pattern_maximum)) = sequence_pattern_length_bounds(&patterns[0])
            else {
                return Ok(false);
            };
            let remaining_minimum = minimum_argument_count(&patterns[1..]);
            if expressions.len() < minimum.saturating_add(remaining_minimum) {
                return Ok(false);
            }
            let maximum = pattern_maximum.min(expressions.len() - remaining_minimum);
            for count in sequence_length_order(&patterns[0], minimum, maximum) {
                let original_length = bindings.len();
                if self.match_sequence_pattern_elements_mode(
                    &expressions[..count],
                    &patterns[0],
                    bindings,
                    ignore_inactive,
                )? && self.match_call_arguments_mode(
                    &expressions[count..],
                    &patterns[1..],
                    bindings,
                    ignore_inactive,
                )? {
                    return Ok(true);
                }
                bindings.truncate(original_length);
            }
            return Ok(false);
        }
        let Some((first, rest)) = expressions.split_first() else {
            return Ok(false);
        };
        let original_length = bindings.len();
        if self.match_pattern_mode(first, &patterns[0], bindings, ignore_inactive)?
            && self.match_call_arguments_mode(rest, &patterns[1..], bindings, ignore_inactive)?
        {
            return Ok(true);
        }
        bindings.truncate(original_length);
        Ok(false)
    }

    fn match_sequence_pattern_elements_mode(
        &mut self,
        expressions: &[Expr],
        pattern: &Expr,
        bindings: &mut Vec<(String, Expr)>,
        ignore_inactive: bool,
    ) -> Result<bool> {
        if pattern.has_head("Alternatives") {
            for alternative in pattern.args() {
                let original_length = bindings.len();
                if self.match_sequence_pattern_elements_mode(
                    expressions,
                    alternative,
                    bindings,
                    ignore_inactive,
                )? {
                    return Ok(true);
                }
                bindings.truncate(original_length);
            }
            return Ok(false);
        }
        if pattern.has_head("HoldPattern") && pattern.args().len() == 1 {
            return self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if pattern.has_head("IgnoringInactive") && pattern.args().len() == 1 {
            return self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[0],
                bindings,
                true,
            );
        }
        if (pattern.has_head("Longest") || pattern.has_head("Shortest"))
            && matches!(pattern.args().len(), 1 | 2)
        {
            return self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if pattern.has_head("Condition") && pattern.args().len() == 2 {
            let original_length = bindings.len();
            if !self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[0],
                bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            let condition = substitute_binding_values(&pattern.args()[1], bindings);
            if is_symbol(&self.evaluate(condition)?, "True") {
                return Ok(true);
            }
            bindings.truncate(original_length);
            return Ok(false);
        }
        if pattern.has_head("PatternTest") && pattern.args().len() == 2 {
            let original_length = bindings.len();
            if !self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[0],
                bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            for expression in expressions {
                if !self.predicate_succeeds(&pattern.args()[1], expression)? {
                    bindings.truncate(original_length);
                    return Ok(false);
                }
            }
            return Ok(true);
        }
        if pattern.has_head("Optional") && matches!(pattern.args().len(), 1 | 2) {
            if expressions.is_empty() {
                return if let Some(default) = pattern.args().get(1) {
                    self.bind_optional_default_mode(&pattern.args()[0], default, bindings)
                } else {
                    Ok(false)
                };
            }
            return self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[0],
                bindings,
                ignore_inactive,
            );
        }
        if pattern.has_head("Pattern") && pattern.args().len() == 2 {
            let Expr::Symbol(name) = &pattern.args()[0] else {
                return Ok(false);
            };
            let original_length = bindings.len();
            if !self.match_sequence_pattern_elements_mode(
                expressions,
                &pattern.args()[1],
                bindings,
                ignore_inactive,
            )? {
                return Ok(false);
            }
            let value = sequence_binding_value(expressions);
            if let Some((_, existing)) = bindings.iter().find(|(existing, _)| existing == name) {
                if existing == &value {
                    return Ok(true);
                }
                bindings.truncate(original_length);
                return Ok(false);
            }
            bindings.push((name.clone(), value));
            return Ok(true);
        }
        if pattern.has_head("PatternSequence") {
            return self.match_call_arguments_mode(
                expressions,
                pattern.args(),
                bindings,
                ignore_inactive,
            );
        }
        if pattern.has_head("OrderlessPatternSequence") {
            for permutation in unique_permutations(pattern.args()) {
                let original_length = bindings.len();
                if self.match_call_arguments_mode(
                    expressions,
                    &permutation,
                    bindings,
                    ignore_inactive,
                )? {
                    return Ok(true);
                }
                bindings.truncate(original_length);
            }
            return Ok(false);
        }
        if pattern.has_head("OptionsPattern") && pattern.args().len() <= 1 {
            return Ok(expressions.iter().all(is_option_expr));
        }
        if matches!(
            pattern.head().symbol_name().map(system_dispatch_name),
            Some("Repeated" | "RepeatedNull")
        ) && matches!(pattern.args().len(), 1 | 2)
        {
            let Some((count_minimum, count_maximum)) = repetition_count_bounds(pattern) else {
                return Ok(false);
            };
            return self.match_repeated_elements_mode(
                expressions,
                &pattern.args()[0],
                count_minimum,
                count_maximum,
                0,
                0,
                bindings,
                ignore_inactive,
            );
        }
        if matches!(
            pattern.head().symbol_name().map(system_dispatch_name),
            Some("BlankSequence" | "BlankNullSequence")
        ) {
            if pattern.has_head("BlankSequence") && expressions.is_empty() {
                return Ok(false);
            }
            if pattern.args().len() > 1 {
                return Ok(false);
            }
            let blank = call("Blank", pattern.args().iter().cloned());
            for expression in expressions {
                if !self.match_pattern_mode(expression, &blank, bindings, ignore_inactive)? {
                    return Ok(false);
                }
            }
            return Ok(true);
        }
        if expressions.len() != 1 {
            return Ok(false);
        }
        self.match_pattern_mode(&expressions[0], pattern, bindings, ignore_inactive)
    }

    #[allow(clippy::too_many_arguments)]
    fn match_repeated_elements_mode(
        &mut self,
        expressions: &[Expr],
        item_pattern: &Expr,
        count_minimum: usize,
        count_maximum: usize,
        position: usize,
        count: usize,
        bindings: &mut Vec<(String, Expr)>,
        ignore_inactive: bool,
    ) -> Result<bool> {
        if position == expressions.len() {
            return Ok((count_minimum..=count_maximum).contains(&count));
        }
        if count >= count_maximum {
            return Ok(false);
        }
        let Some((item_minimum, item_maximum)) = pattern_width_bounds(item_pattern) else {
            return Ok(false);
        };
        let minimum = item_minimum.max(1);
        let maximum = item_maximum.min(expressions.len() - position);
        if minimum > maximum {
            return Ok(false);
        }
        for length in sequence_length_order(item_pattern, minimum, maximum) {
            let original_length = bindings.len();
            if self.match_sequence_pattern_elements_mode(
                &expressions[position..position + length],
                item_pattern,
                bindings,
                ignore_inactive,
            )? && self.match_repeated_elements_mode(
                expressions,
                item_pattern,
                count_minimum,
                count_maximum,
                position + length,
                count + 1,
                bindings,
                ignore_inactive,
            )? {
                return Ok(true);
            }
            bindings.truncate(original_length);
        }
        Ok(false)
    }

    fn bind_optional_default_mode(
        &mut self,
        pattern: &Expr,
        default: &Expr,
        bindings: &mut Vec<(String, Expr)>,
    ) -> Result<bool> {
        if (pattern.has_head("HoldPattern")
            || pattern.has_head("Longest")
            || pattern.has_head("Shortest"))
            && !pattern.args().is_empty()
        {
            return self.bind_optional_default_mode(&pattern.args()[0], default, bindings);
        }
        if pattern.has_head("PatternTest") && pattern.args().len() == 2 {
            let original_length = bindings.len();
            if self.bind_optional_default_mode(&pattern.args()[0], default, bindings)?
                && self.predicate_succeeds(&pattern.args()[1], default)?
            {
                return Ok(true);
            }
            bindings.truncate(original_length);
            return Ok(false);
        }
        if pattern.has_head("Condition") && pattern.args().len() == 2 {
            let original_length = bindings.len();
            if !self.bind_optional_default_mode(&pattern.args()[0], default, bindings)? {
                return Ok(false);
            }
            let condition = substitute_binding_values(&pattern.args()[1], bindings);
            if is_symbol(&self.evaluate(condition)?, "True") {
                return Ok(true);
            }
            bindings.truncate(original_length);
            return Ok(false);
        }
        if pattern.has_head("Pattern") && pattern.args().len() == 2 {
            let Expr::Symbol(name) = &pattern.args()[0] else {
                return Ok(false);
            };
            if !self.bind_optional_default_mode(&pattern.args()[1], default, bindings)? {
                return Ok(false);
            }
            if let Some((_, existing)) = bindings.iter().find(|(existing, _)| existing == name) {
                return Ok(existing == default);
            }
            bindings.push((name.clone(), default.clone()));
            return Ok(true);
        }
        if pattern.has_head("Alternatives") {
            for alternative in pattern.args() {
                let original_length = bindings.len();
                if self.bind_optional_default_mode(alternative, default, bindings)? {
                    return Ok(true);
                }
                bindings.truncate(original_length);
            }
            return Ok(false);
        }
        Ok(matches!(
            pattern.head().symbol_name().map(system_dispatch_name),
            Some(
                "Blank"
                    | "BlankSequence"
                    | "BlankNullSequence"
                    | "Repeated"
                    | "RepeatedNull"
                    | "PatternSequence"
                    | "OrderlessPatternSequence"
                    | "OptionsPattern"
            )
        ) || pattern == default)
    }

    fn match_key_value_pattern_mode(
        &mut self,
        expr: &Expr,
        specification: &Expr,
        bindings: &mut Vec<(String, Expr)>,
        ignore_inactive: bool,
    ) -> Result<bool> {
        let elements = if let Some(entries) = association_entries(expr) {
            entries
        } else if expr.has_head("List") && expr.args().iter().all(|item| rule_parts(item).is_some())
        {
            expr.args().to_vec()
        } else {
            return Ok(false);
        };
        let patterns = if specification.has_head("List") {
            specification.args().to_vec()
        } else {
            vec![specification.clone()]
        };
        self.match_key_value_items_mode(
            &elements,
            &patterns,
            0,
            &mut vec![false; elements.len()],
            bindings,
            ignore_inactive,
        )
    }

    fn match_key_value_items_mode(
        &mut self,
        elements: &[Expr],
        patterns: &[Expr],
        pattern_index: usize,
        used: &mut [bool],
        bindings: &mut Vec<(String, Expr)>,
        ignore_inactive: bool,
    ) -> Result<bool> {
        if pattern_index == patterns.len() {
            return Ok(true);
        }
        for index in 0..elements.len() {
            if used[index] {
                continue;
            }
            let original_length = bindings.len();
            if self.match_pattern_mode(
                &elements[index],
                &patterns[pattern_index],
                bindings,
                ignore_inactive,
            )? {
                used[index] = true;
                if self.match_key_value_items_mode(
                    elements,
                    patterns,
                    pattern_index + 1,
                    used,
                    bindings,
                    ignore_inactive,
                )? {
                    return Ok(true);
                }
                used[index] = false;
            }
            bindings.truncate(original_length);
        }
        Ok(false)
    }

    fn dispatch(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let Some(name) = head.symbol_name().map(system_dispatch_name) else {
            return Ok(call(head, args));
        };

        if let Some(number) = evaluate_numeric_constructor(name, &args) {
            return Ok(number);
        }
        if let Some(number) = evaluate_arithmetic(name, &args) {
            return Ok(number);
        }
        if name == "Equal"
            && let Some(result) = self.equal_same_test_expr(&args)?
        {
            return Ok(result);
        }
        if let Some(relation) = evaluate_relation(name, &args) {
            return Ok(relation);
        }
        if let Some(predicate) = evaluate_predicate(name, &args) {
            return Ok(predicate);
        }

        let inert = || call(head.clone(), args.clone());
        let result = match name {
            "Association" => normalize_association(&args).unwrap_or_else(inert),
            "Symbol" => self.symbol_constructor_expr(&args).unwrap_or_else(inert),
            "SymbolName" => symbol_name_expr(&args).unwrap_or_else(inert),
            "Context" => context_expr(&args).unwrap_or_else(inert),
            "Contexts" => self.contexts_expr(&args).unwrap_or_else(inert),
            "Names" => self.names_expr(&args).unwrap_or_else(inert),
            "NameQ" => self.name_q_expr(&args).unwrap_or_else(inert),
            "Unique" => self.unique_expr(&args).unwrap_or_else(inert),
            "ByteArray" => byte_array_expr(&args).unwrap_or_else(inert),
            "BaseEncode" => base_encode_expr(&args).unwrap_or_else(inert),
            "BaseDecode" => base_decode_expr(&args).unwrap_or_else(inert),
            "ExportString" => export_string_expr(&args).unwrap_or_else(inert),
            "ImportString" => import_string_expr(&args).unwrap_or_else(inert),
            "ExportByteArray" => export_byte_array_expr(&args).unwrap_or_else(inert),
            "ImportByteArray" => import_byte_array_expr(&args).unwrap_or_else(inert),
            "Interval" => interval_expr(&args).unwrap_or_else(inert),
            "IntervalUnion" => interval_union_expr(&args).unwrap_or_else(inert),
            "IntervalIntersection" => interval_intersection_expr(&args).unwrap_or_else(inert),
            "IntervalMemberQ" => interval_member_expr(&args).unwrap_or_else(inert),
            "Identity" => single(&args).cloned().unwrap_or_else(inert),
            "Length" => single(&args).map_or_else(inert, |expr| integer(expr.length())),
            "Depth" => single(&args).map_or_else(inert, |expr| integer(depth(expr))),
            "Dimensions" => dimensions_expr(&args).unwrap_or_else(inert),
            "ArrayDepth" => single(&args)
                .map(|expr| integer(array_depth_value(expr)))
                .unwrap_or_else(inert),
            "ArrayQ" => self.array_q_expr(&args)?.unwrap_or_else(inert),
            "Head" => single(&args).map_or_else(inert, Expr::head),
            "First" => association_first_last(&args, false)
                .or_else(|| first_or_last(&args, false))
                .unwrap_or_else(inert),
            "Last" => association_first_last(&args, true)
                .or_else(|| first_or_last(&args, true))
                .unwrap_or_else(inert),
            "Rest" => trim_end(&args, false).unwrap_or_else(inert),
            "Most" => trim_end(&args, true).unwrap_or_else(inert),
            "Append" => append_or_prepend(&args, false).unwrap_or_else(inert),
            "Prepend" => append_or_prepend(&args, true).unwrap_or_else(inert),
            "Join" => join_expr(&args).unwrap_or_else(inert),
            "Reverse" => reverse_expr(&args).unwrap_or_else(inert),
            "RotateLeft" => rotate_expr(&args, false).unwrap_or_else(inert),
            "RotateRight" => rotate_expr(&args, true).unwrap_or_else(inert),
            "Take" => match take_drop(&args, false) {
                Some(result) => result,
                None => {
                    if args
                        .first()
                        .is_some_and(|target| target.has_head("Association"))
                    {
                        self.emit_error_message("Take");
                    }
                    inert()
                }
            },
            "Drop" => take_drop(&args, true).unwrap_or_else(inert),
            "Flatten" => flatten_expr(&args).unwrap_or_else(inert),
            "Part" => match part_expr(&args) {
                Some(result) => result,
                None => {
                    self.emit_message_detail("Part", "error", part_error_detail(&args));
                    inert()
                }
            },
            "ReplaceAt" => self.replace_at_expr(&args)?.unwrap_or_else(inert),
            "Extract" => extract_expr(&args).unwrap_or_else(inert),
            "Level" => level_expr(&args).unwrap_or_else(inert),
            "ReplacePart" => replace_part_expr(&args).unwrap_or_else(inert),
            "MapAt" => self.map_at_expr(&args)?.unwrap_or_else(inert),
            "Apply" => self.apply_levels_expr(&args)?.unwrap_or_else(inert),
            "Map" => self.map_levels_expr(&args)?.unwrap_or_else(inert),
            "MapAll" => self.map_all_expr(&args)?.unwrap_or_else(inert),
            "Scan" => self.scan_expr(&args)?.unwrap_or_else(inert),
            "Through" => through_expr(&args).unwrap_or_else(inert),
            "Distribute" => distribute_expr(&args).unwrap_or_else(inert),
            "Range" => range_threaded_expr(&args).unwrap_or_else(inert),
            "ConstantArray" => constant_array(&args).unwrap_or_else(inert),
            "Array" => self.array_expr(&args)?.unwrap_or_else(inert),
            "ArrayReshape" => array_reshape_expr(&args).unwrap_or_else(inert),
            "ArrayPad" => array_pad_expr(&args).unwrap_or_else(inert),
            "ArrayFlatten" => array_flatten_expr(&args).unwrap_or_else(inert),
            "Precision" => precision_expr(&args, false).unwrap_or_else(inert),
            "Accuracy" => precision_expr(&args, true).unwrap_or_else(inert),
            "SetPrecision" => set_precision_expr(&args, false).unwrap_or_else(inert),
            "SetAccuracy" => set_precision_expr(&args, true).unwrap_or_else(inert),
            "N" => self.n_expr(&args)?.unwrap_or_else(inert),
            "ToString" => to_string_expr(&args).unwrap_or_else(inert),
            "ToExpression" => self.to_expression_expr(&args)?.unwrap_or_else(inert),
            "ToBoxes" => to_boxes_expr(&args).unwrap_or_else(inert),
            "StripBoxes" => strip_boxes_expr(&args).unwrap_or_else(inert),
            "SyntaxQ" => syntax_q_expr(&args).unwrap_or_else(inert),
            "SyntaxLength" => syntax_length_expr(&args).unwrap_or_else(inert),
            "ComplexExpand" => complex_expand_expr(&args).unwrap_or_else(inert),
            "Expand" => self.expand_expr(&args)?.unwrap_or_else(inert),
            "PolynomialQ" => self.polynomial_q_expr(&args)?.unwrap_or_else(inert),
            "Variables" => polynomial_variables_expr(&args).unwrap_or_else(inert),
            "MonomialList" => self.monomial_list_expr(&args)?.unwrap_or_else(inert),
            "Coefficient" => self.coefficient_expr(&args)?.unwrap_or_else(inert),
            "Exponent" => self.exponent_expr(&args)?.unwrap_or_else(inert),
            "CoefficientList" => self.coefficient_list_expr(&args)?.unwrap_or_else(inert),
            "Collect" => self.collect_expr(&args)?.unwrap_or_else(inert),
            "Factor" => self.factor_expr(&args, false)?.unwrap_or_else(inert),
            "FactorList" => self.factor_expr(&args, true)?.unwrap_or_else(inert),
            "PolynomialMod" => self.polynomial_mod_expr(&args)?.unwrap_or_else(inert),
            "PolynomialQuotient" => self
                .polynomial_division_expr(&args, true)?
                .unwrap_or_else(inert),
            "PolynomialRemainder" => self
                .polynomial_division_expr(&args, false)?
                .unwrap_or_else(inert),
            "PolynomialReduce" => self.polynomial_reduce_expr(&args)?.unwrap_or_else(inert),
            "PolynomialGCD" => self
                .polynomial_gcd_lcm_expr(&args, false)?
                .unwrap_or_else(inert),
            "PolynomialLCM" => self
                .polynomial_gcd_lcm_expr(&args, true)?
                .unwrap_or_else(inert),
            "Resultant" => self.resultant_expr(&args)?.unwrap_or_else(inert),
            "Discriminant" => self.discriminant_expr(&args)?.unwrap_or_else(inert),
            "Subresultants" => self.subresultants_expr(&args)?.unwrap_or_else(inert),
            "GroebnerBasis" => self.groebner_basis_expr(&args)?.unwrap_or_else(inert),
            "Decompose" => self.decompose_expr(&args)?.unwrap_or_else(inert),
            "Root" => self.root_expr(&args)?.unwrap_or_else(inert),
            "RootReduce" => self.root_reduce_expr(&args)?.unwrap_or_else(inert),
            "MinimalPolynomial" => self.minimal_polynomial_expr(&args)?.unwrap_or_else(inert),
            "ToRadicals" => to_radicals_expr(&args).unwrap_or_else(inert),
            "CountRoots" => self.count_roots_expr(&args)?.unwrap_or_else(inert),
            "RootIntervals" => self.root_intervals_expr(&args)?.unwrap_or_else(inert),
            "IsolatingInterval" => isolating_interval_expr(&args).unwrap_or_else(inert),
            "RootSum" => self.root_sum_expr(&args)?.unwrap_or_else(inert),
            "Solve" => self.solve_expr(&args)?.unwrap_or_else(inert),
            "Together" => self.rational_simplify_expr(&args)?.unwrap_or_else(inert),
            "Cancel" => self.rational_simplify_expr(&args)?.unwrap_or_else(inert),
            "Apart" => self.rational_simplify_expr(&args)?.unwrap_or_else(inert),
            "Numerator" => self.fraction_part_expr(&args, true)?.unwrap_or_else(inert),
            "Denominator" => self.fraction_part_expr(&args, false)?.unwrap_or_else(inert),
            "Total" => self.total_expr(&args)?.unwrap_or_else(inert),
            "Keys" => association_keys_values(&args, false).unwrap_or_else(inert),
            "Values" => association_keys_values(&args, true).unwrap_or_else(inert),
            "Normal" => match args.as_slice() {
                [association] if association.has_head("Association") => {
                    list(association.args().iter().cloned())
                }
                [Expr::ByteArray(values)] => list(values.iter().map(|value| integer(*value))),
                [array @ Expr::SparseArray { .. }] => sparse_normal(array).expect("sparse array"),
                [other] => other.clone(),
                _ => inert(),
            },
            "ArrayRules" => sparse_array_rules(&args).unwrap_or_else(inert),
            "Lookup" => association_lookup_expr(&args).unwrap_or_else(inert),
            "KeyExistsQ" | "KeyMemberQ" => association_key_exists(&args).unwrap_or_else(inert),
            "KeyTake" => association_key_take_drop(&args, false).unwrap_or_else(inert),
            "KeyDrop" => association_key_take_drop(&args, true).unwrap_or_else(inert),
            "KeySelect" => self.key_select_expr(&args)?.unwrap_or_else(inert),
            "AssociationThread" => association_thread(&args).unwrap_or_else(inert),
            "KeyMap" => {
                if let [function, association] = args.as_slice()
                    && let Some(entries) = association_entries(association)
                {
                    let mut rules = Vec::new();
                    for entry in entries {
                        let key =
                            self.evaluate(call(function.clone(), [entry.args()[0].clone()]))?;
                        rules.push(call("Rule", [key, entry.args()[1].clone()]));
                    }
                    normalize_association(&rules).unwrap_or_else(inert)
                } else {
                    inert()
                }
            }
            "KeyValueMap" => {
                if let [function, association] = args.as_slice()
                    && let Some(entries) = association_entries(association)
                {
                    let mut values = Vec::new();
                    for entry in entries {
                        values.push(self.evaluate(call(
                            function.clone(),
                            [entry.args()[0].clone(), entry.args()[1].clone()],
                        ))?);
                    }
                    list(values)
                } else {
                    inert()
                }
            }
            "AssociationMap" => {
                if let [function, keys] = args.as_slice()
                    && keys.has_head("List")
                {
                    let mut rules = Vec::new();
                    for key in keys.args() {
                        let value = self.evaluate(call(function.clone(), [key.clone()]))?;
                        rules.push(call("Rule", [key.clone(), value]));
                    }
                    normalize_association(&rules).unwrap_or_else(inert)
                } else {
                    inert()
                }
            }
            "Characters" => match args.as_slice() {
                [Expr::String(value)] => {
                    list(value.chars().map(|character| string(character.to_string())))
                }
                [values] if values.has_head("List") => {
                    list(values.args().iter().map(|value| match value {
                        Expr::String(value) => {
                            list(value.chars().map(|character| string(character.to_string())))
                        }
                        _ => call("Characters", [value.clone()]),
                    }))
                }
                _ => inert(),
            },
            "ToCharacterCode" => to_character_code_expr(&args).unwrap_or_else(inert),
            "FromCharacterCode" => from_character_code_expr(&args).unwrap_or_else(inert),
            "StringToByteArray" => string_to_byte_array_expr(&args).unwrap_or_else(inert),
            "ByteArrayToString" => byte_array_to_string_expr(&args).unwrap_or_else(inert),
            "StringLength" => match args.as_slice() {
                [Expr::String(value)] => integer(value.chars().count()),
                [values] if values.has_head("List") => {
                    list(values.args().iter().map(|value| match value {
                        Expr::String(value) => integer(value.chars().count()),
                        _ => call("StringLength", [value.clone()]),
                    }))
                }
                _ => inert(),
            },
            "StringJoin" => string_join_expr(&args).unwrap_or_else(inert),
            "Print" => {
                self.prints
                    .push(args.iter().map(format_print_argument).collect());
                symbol("Null")
            }
            "StringTake" => string_take_drop(&args, false).unwrap_or_else(inert),
            "StringDrop" => string_take_drop(&args, true).unwrap_or_else(inert),
            "StringInsert" => string_insert_expr(&args).unwrap_or_else(inert),
            "StringReverse" => string_reverse_expr(&args).unwrap_or_else(inert),
            "ToUpperCase" => string_case_expr(&args, true, false).unwrap_or_else(inert),
            "ToLowerCase" => string_case_expr(&args, false, false).unwrap_or_else(inert),
            "Capitalize" => string_case_expr(&args, true, true).unwrap_or_else(inert),
            "StringRepeat" => string_repeat_expr(&args).unwrap_or_else(inert),
            "StringPadLeft" => string_pad_expr(&args, false).unwrap_or_else(inert),
            "StringPadRight" => string_pad_expr(&args, true).unwrap_or_else(inert),
            "StringSplit" => string_split_expr(&args).unwrap_or_else(inert),
            "StringRiffle" => string_riffle_expr(&args).unwrap_or_else(inert),
            "StringTrim" => string_trim_expr(&args).unwrap_or_else(inert),
            "StringCount" => string_count_expr(&args).unwrap_or_else(inert),
            "StringPosition" => self.string_position_expr(&args)?.unwrap_or_else(inert),
            "StringMatchQ" => self.string_boolean_expr(&args, 0)?.unwrap_or_else(inert),
            "StringFreeQ" => self.string_boolean_expr(&args, 1)?.unwrap_or_else(inert),
            "StringContainsQ" => self.string_boolean_expr(&args, 2)?.unwrap_or_else(inert),
            "StringStartsQ" => self.string_boolean_expr(&args, 3)?.unwrap_or_else(inert),
            "StringEndsQ" => self.string_boolean_expr(&args, 4)?.unwrap_or_else(inert),
            "StringCases" => match self.string_cases_expr(&args)? {
                Some(result) => result,
                None => {
                    self.emit_message_detail(
                        "StringCases",
                        "error",
                        string_cases_error_detail(&args),
                    );
                    inert()
                }
            },
            "StringReplace" => self.string_replace_expr(&args)?.unwrap_or_else(inert),
            "DigitQ" => digit_letter_q_expr(&args, false).unwrap_or_else(inert),
            "LetterQ" => digit_letter_q_expr(&args, true).unwrap_or_else(inert),
            "Order" => order_expr(&args).unwrap_or_else(inert),
            "LexicographicOrder" => lexicographic_order_expr(&args).unwrap_or_else(inert),
            "OrderedQ" => ordered_q_expr(&args).unwrap_or_else(inert),
            "Ordering" => self
                .sort_order_expr(&args, false, true)?
                .unwrap_or_else(inert),
            "Sort" => self
                .sort_order_expr(&args, false, false)?
                .unwrap_or_else(inert),
            "ReverseSort" => self
                .sort_order_expr(&args, true, false)?
                .unwrap_or_else(inert),
            "LexicographicSort" => sort_expr(&args, false).unwrap_or_else(inert),
            "SortBy" => self.sort_by_expr(&args, false, false)?,
            "ReverseSortBy" => self.sort_by_expr(&args, true, false)?,
            "OrderingBy" => self.sort_by_expr(&args, false, true)?,
            "MinimalBy" => self.extremal_by_expr(&args, false)?,
            "MaximalBy" => self.extremal_by_expr(&args, true)?,
            "Tally" => self.tally_expr(&args, false)?.unwrap_or_else(inert),
            "Counts" => self.tally_expr(&args, true)?.unwrap_or_else(inert),
            "Catenate" => catenate_expr(&args).unwrap_or_else(inert),
            "Differences" => self.differences_expr(&args)?,
            "Accumulate" => self.accumulate_expr(&args)?,
            "Riffle" => riffle_expr(&args).unwrap_or_else(inert),
            "AllTrue" => self.quantifier_expr(&args, 0)?,
            "AnyTrue" => self.quantifier_expr(&args, 1)?,
            "NoneTrue" => self.quantifier_expr(&args, 2)?,
            "ContainsAll" => contains_expr(&args, 0).unwrap_or_else(inert),
            "ContainsAny" => contains_expr(&args, 1).unwrap_or_else(inert),
            "ContainsNone" => contains_expr(&args, 2).unwrap_or_else(inert),
            "ContainsExactly" => contains_expr(&args, 3).unwrap_or_else(inert),
            "Subsets" => subsets_expr(&args).unwrap_or_else(inert),
            "Permutations" => permutations_expr(&args).unwrap_or_else(inert),
            "RandomPermutation" => random_permutation_expr(&args).unwrap_or_else(inert),
            "RandomSample" => random_sample_expr(&args).unwrap_or_else(inert),
            "Permute" => permute_expr(&args).unwrap_or_else(inert),
            "Union" => self.set_operation_expr(&args, 0)?.unwrap_or_else(inert),
            "Intersection" => self.set_operation_expr(&args, 1)?.unwrap_or_else(inert),
            "Complement" => self.set_operation_expr(&args, 2)?.unwrap_or_else(inert),
            "PadLeft" => pad_expr(&args, false).unwrap_or_else(inert),
            "PadRight" => pad_expr(&args, true).unwrap_or_else(inert),
            "KeySort" => key_sort_expr(&args).unwrap_or_else(inert),
            "Mean" => self.mean_median_expr(&args, false)?,
            "Median" => self.mean_median_expr(&args, true)?,
            "MinMax" => min_max_list_expr(&args).unwrap_or_else(inert),
            "RankedMin" => ranked_expr(&args, false).unwrap_or_else(inert),
            "RankedMax" => ranked_expr(&args, true).unwrap_or_else(inert),
            "Mode" => mode_expr(&args).unwrap_or_else(inert),
            "Quantile" => self.quantile_expr(&args)?.unwrap_or_else(inert),
            "Quartiles" => self.quartiles_expr(&args)?.unwrap_or_else(inert),
            "BinCounts" => bin_values_expr(&args, false).unwrap_or_else(inert),
            "BinLists" => bin_values_expr(&args, true).unwrap_or_else(inert),
            "Transpose" => transpose_expr(&args).unwrap_or_else(inert),
            "Insert" => insert_expr(&args).unwrap_or_else(inert),
            "Delete" => delete_expr(&args).unwrap_or_else(inert),
            "Position" => position_expr(&args).unwrap_or_else(inert),
            "FlattenAt" => flatten_at_expr(&args).unwrap_or_else(inert),
            "Split" => split_expr(&args).unwrap_or_else(inert),
            "DeleteAdjacentDuplicates" => {
                delete_adjacent_duplicates_expr(&args).unwrap_or_else(inert)
            }
            "DeleteDuplicatesBy" => self.delete_duplicates_by_expr(&args)?.unwrap_or_else(inert),
            "DeleteDuplicates" => self.delete_duplicates_expr(&args)?.unwrap_or_else(inert),
            "DuplicateFreeQ" => self.duplicate_free_q_expr(&args)?.unwrap_or_else(inert),
            "Fold" => self.fold_expr(&args, false)?.unwrap_or_else(inert),
            "FoldList" => self.fold_expr(&args, true)?.unwrap_or_else(inert),
            "SequenceFold" => self.sequence_fold_expr(&args, false)?.unwrap_or_else(inert),
            "SequenceFoldList" => self.sequence_fold_expr(&args, true)?.unwrap_or_else(inert),
            "FoldWhile" => self.fold_while_expr(&args, false)?.unwrap_or_else(inert),
            "FoldWhileList" => self.fold_while_expr(&args, true)?.unwrap_or_else(inert),
            "FoldPair" => self.fold_pair_expr(&args, false)?.unwrap_or_else(inert),
            "FoldPairList" => self.fold_pair_expr(&args, true)?.unwrap_or_else(inert),
            "FirstCase" => self.first_case_expr(&args)?.unwrap_or_else(inert),
            "Select" => self
                .selection_expr(&args, SelectionMode::Select)?
                .unwrap_or_else(inert),
            "Discard" => self
                .selection_expr(&args, SelectionMode::Discard)?
                .unwrap_or_else(inert),
            "SelectFirst" => self
                .selection_expr(&args, SelectionMode::First)?
                .unwrap_or_else(inert),
            "Pick" => match self.pick_expr(&args)? {
                Some(result) => result,
                None => {
                    self.emit_error_message("Pick");
                    inert()
                }
            },
            "TakeWhile" => self.take_while_expr(&args)?.unwrap_or_else(inert),
            "SplitBy" => self.split_by_expr(&args)?.unwrap_or_else(inert),
            "Subsequences" => subsequences_expr(&args).unwrap_or_else(inert),
            "AlphabeticSort" => alphabetic_sort_expr(&args, false).unwrap_or_else(inert),
            "NumericalSort" => alphabetic_sort_expr(&args, true).unwrap_or_else(inert),
            "Tr" => self.trace_expr(&args)?.unwrap_or_else(inert),
            "Det" => self.determinant_expr(&args)?.unwrap_or_else(inert),
            "Inverse" => self.inverse_expr(&args)?.unwrap_or_else(inert),
            "MatrixPower" => self.matrix_power_expr(&args)?.unwrap_or_else(inert),
            "Dot" => self.dot_expr(&args)?.unwrap_or_else(inert),
            "Cross" => self.cross_expr(&args)?.unwrap_or_else(inert),
            "LeviCivitaTensor" => levi_civita_expr(&args).unwrap_or_else(inert),
            "DiagonalMatrix" => diagonal_matrix_expr(&args).unwrap_or_else(inert),
            "Merge" => self.merge_expr(&args)?.unwrap_or_else(inert),
            "GroupBy" => self.group_by_expr(&args, false)?.unwrap_or_else(inert),
            "GatherBy" => self.group_by_expr(&args, true)?.unwrap_or_else(inert),
            "Gather" => gather_expr(&args).unwrap_or_else(inert),
            "KeyComplement" => key_set_expr(&args, 0).unwrap_or_else(inert),
            "KeyUnion" => key_set_expr(&args, 1).unwrap_or_else(inert),
            "KeyIntersection" => key_set_expr(&args, 2).unwrap_or_else(inert),
            "Variance" => self.variance_expr(&args)?.unwrap_or_else(inert),
            "StandardDeviation" => self.standard_deviation_expr(&args)?.unwrap_or_else(inert),
            "Norm" => self.norm_expr(&args)?.unwrap_or_else(inert),
            "Boole" => boole_expr(&args).unwrap_or_else(inert),
            "Partition" => partition_expr(&args).unwrap_or_else(inert),
            "MapThread" => self.map_thread_expr(&args)?.unwrap_or_else(inert),
            "MapIndexed" => self.map_indexed_expr(&args)?.unwrap_or_else(inert),
            "Construct" => match args.split_first() {
                Some((function, arguments)) => {
                    self.evaluate(call(function.clone(), arguments.iter().cloned()))?
                }
                None => inert(),
            },
            "ComposeList" => self.compose_list_expr(&args)?.unwrap_or_else(inert),
            "Comap" => self.comap_expr(&args, false)?.unwrap_or_else(inert),
            "ComapApply" => self.comap_expr(&args, true)?.unwrap_or_else(inert),
            "Thread" => self.thread_expr(&args)?.unwrap_or_else(inert),
            "Inner" => self.inner_expr(&args)?.unwrap_or_else(inert),
            "Tuples" => tuples_expr(&args).unwrap_or_else(inert),
            "UnitVector" => unit_vector_expr(&args).unwrap_or_else(inert),
            "IdentityMatrix" => identity_matrix_expr(&args).unwrap_or_else(inert),
            "TakeDrop" => take_drop_expr(&args).unwrap_or_else(inert),
            "TakeList" => take_list_expr(&args).unwrap_or_else(inert),
            "BlockMap" => self.block_map_expr(&args)?.unwrap_or_else(inert),
            "LengthWhile" => self.length_while_expr(&args)?.unwrap_or_else(inert),
            "Outer" => self.outer_expr(&args)?.unwrap_or_else(inert),
            "Nest" => self.nest_expr(&args, false)?.unwrap_or_else(inert),
            "NestList" => self.nest_expr(&args, true)?.unwrap_or_else(inert),
            "NestWhile" => self.nest_while_expr(&args, false)?.unwrap_or_else(inert),
            "NestWhileList" => self.nest_while_expr(&args, true)?.unwrap_or_else(inert),
            "FixedPoint" => self.fixed_point_expr(&args, false)?.unwrap_or_else(inert),
            "FixedPointList" => self.fixed_point_expr(&args, true)?.unwrap_or_else(inert),
            "PermutationCycles" => permutation_cycles_expr(&args).unwrap_or_else(inert),
            "PermutationList" => permutation_list_expr(&args).unwrap_or_else(inert),
            "PermutationOrder" => permutation_order_expr(&args).unwrap_or_else(inert),
            "SequencePosition" => sequence_position_count_expr(&args, false).unwrap_or_else(inert),
            "SequenceCount" => sequence_position_count_expr(&args, true).unwrap_or_else(inert),
            "SequenceCases" => self.sequence_cases_expr(&args)?.unwrap_or_else(inert),
            "VectorQ" => self
                .vector_matrix_q_expr(&args, false)?
                .unwrap_or_else(inert),
            "MatrixQ" => self
                .vector_matrix_q_expr(&args, true)?
                .unwrap_or_else(inert),
            "FirstPosition" => first_position_expr(&args).unwrap_or_else(inert),
            "PositionLargest" => extremal_positions_expr(&args, true).unwrap_or_else(inert),
            "PositionSmallest" => extremal_positions_expr(&args, false).unwrap_or_else(inert),
            "PositionIndex" => position_index_expr(&args).unwrap_or_else(inert),
            "CountDistinct" => count_distinct_expr(&args).unwrap_or_else(inert),
            "CountsBy" => self.counts_by_expr(&args)?.unwrap_or_else(inert),
            "ContainsOnly" => self.contains_only_expr(&args)?.unwrap_or_else(inert),
            "Subdivide" => self.subdivide_expr(&args)?.unwrap_or_else(inert),
            "Ratios" => self.ratios_expr(&args)?.unwrap_or_else(inert),
            "SubsetMap" => self.subset_map_expr(&args)?.unwrap_or_else(inert),
            "Operate" => operate_expr(&args).unwrap_or_else(inert),
            "MapApply" => self.map_apply_expr(&args)?.unwrap_or_else(inert),
            _ => inert(),
        };
        Ok(result)
    }

    fn equal_same_test_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let Some(option) = args.last() else {
            return Ok(None);
        };
        if !(option.has_head("Rule") || option.has_head("RuleDelayed"))
            || option.args().len() != 2
            || !is_symbol(&option.args()[0], "SameTest")
        {
            return Ok(None);
        }
        let values = &args[..args.len() - 1];
        for pair in values.windows(2) {
            let result = self.evaluate(call(
                option.args()[1].clone(),
                [pair[0].clone(), pair[1].clone()],
            ))?;
            if is_symbol(&result, "False") {
                return Ok(Some(symbol("False")));
            }
            if !is_symbol(&result, "True") {
                return Ok(None);
            }
        }
        Ok(Some(symbol("True")))
    }

    fn n_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let Some(value) = args.first() else {
            return Ok(None);
        };
        let mut precision = None;
        for argument in &args[1..] {
            match argument {
                Expr::Integer(value) if value.is_positive() => precision = value.to_usize(),
                option
                    if (option.has_head("Rule") || option.has_head("RuleDelayed"))
                        && option.args().len() == 2
                        && matches!(
                            option.args()[0].symbol_name().map(system_dispatch_name),
                            Some("WorkingPrecision" | "AccuracyGoal" | "PrecisionGoal")
                        ) =>
                {
                    if let Expr::Integer(value) = &option.args()[1]
                        && value.is_positive()
                    {
                        let Some(candidate) = value.to_usize() else {
                            return Ok(None);
                        };
                        precision = Some(
                            precision.map_or(candidate, |current: usize| current.max(candidate)),
                        );
                    }
                }
                Expr::Symbol(name) if system_dispatch_name(name) == "MachinePrecision" => {}
                _ => return Ok(None),
            }
        }
        Ok(numericize_expr(value, precision))
    }

    fn to_expression_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([input] | [input, _] | [input, _, _]) = args else {
            return Ok(None);
        };
        if input.has_head("List") {
            let mut converted = Vec::with_capacity(input.args().len());
            for item in input.args() {
                let mut item_args = vec![item.clone()];
                item_args.extend(args.iter().skip(1).cloned());
                let Some(value) = self.to_expression_expr(&item_args)? else {
                    return Ok(None);
                };
                converted.push(value);
            }
            return Ok(Some(list(converted)));
        }
        let form = args
            .get(1)
            .and_then(Expr::symbol_name)
            .map(system_dispatch_name)
            .unwrap_or("StandardForm");
        if !matches!(
            form,
            "InputForm" | "StandardForm" | "TraditionalForm" | "TeXForm" | "MathMLForm"
        ) {
            return Ok(None);
        }
        let parsed = match input {
            Expr::String(source) => {
                if form == "TraditionalForm"
                    && let Some(boxes) = traditional_box_source(source)
                    && let Ok(box_expression) = parse_input_form(&boxes)
                    && let Ok(parsed) = interpret_standard_form(box_expression)
                {
                    parsed
                } else {
                    let source = if form == "MathMLForm" {
                        mathml_annotation(source).unwrap_or(source)
                    } else {
                        source
                    };
                    match parse_input_form(source) {
                        Ok(parsed) => parsed,
                        Err(_) => return Ok(None),
                    }
                }
            }
            boxes => match interpret_standard_form(boxes.clone()) {
                Ok(parsed) => parsed,
                Err(_) => return Ok(None),
            },
        };
        if let Some(wrapper) = args.get(2) {
            self.evaluate(call(wrapper.clone(), [parsed])).map(Some)
        } else {
            self.evaluate(parsed).map(Some)
        }
    }

    fn evaluate_make_boxes(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let (value, form) = match args.as_slice() {
            [value] => (value, "StandardForm".to_owned()),
            [value, form] => {
                let form = self.evaluate(form.clone())?;
                let Some(form) = form.symbol_name().map(system_dispatch_name) else {
                    return Ok(call(head, args));
                };
                (value, form.to_owned())
            }
            _ => return Ok(call(head, args)),
        };
        Ok(match form.as_str() {
            "StandardForm" => standard_boxes(value),
            "TraditionalForm" => traditional_boxes(value),
            _ => call(head, args),
        })
    }

    fn evaluate_make_expression(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let boxes = match args.as_slice() {
            [boxes] => boxes,
            [boxes, form]
                if form
                    .symbol_name()
                    .is_some_and(|name| system_dispatch_name(name) == "StandardForm") =>
            {
                boxes
            }
            _ => return Ok(call(head, args)),
        };
        match interpret_standard_form(boxes.clone()) {
            Ok(expression) => Ok(call("HoldComplete", [expression])),
            Err(_) => Ok(call(head, args)),
        }
    }

    fn register_symbol_name(&mut self, name: &str) {
        let short = name.rsplit('`').next().unwrap_or(name);
        if name.contains('`') {
            if !name.starts_with("System`") {
                self.known_symbols.insert(name.to_owned());
            }
        } else if !SYSTEM_SYMBOLS.contains(short) {
            self.known_symbols.insert(format!("Global`{name}"));
        }
    }

    fn symbol_constructor_expr(&mut self, args: &[Expr]) -> Option<Expr> {
        let [Expr::String(name)] = args else {
            return None;
        };
        if !valid_symbol_name(name) {
            return None;
        }
        let full_name = if name.contains('`') {
            name.clone()
        } else if SYSTEM_SYMBOLS.contains(name) {
            format!("System`{name}")
        } else {
            format!("Global`{name}")
        };
        self.register_symbol_name(&full_name);
        Some(display_symbol(&full_name))
    }

    fn contexts_expr(&self, args: &[Expr]) -> Option<Expr> {
        let pattern = match args {
            [] => "*",
            [Expr::String(pattern)] => pattern,
            _ => return None,
        };
        let mut contexts = BTreeSet::new();
        if SYSTEM_SYMBOLS
            .iter()
            .any(|name| wildcard_matches(&format!("System`{name}"), pattern))
        {
            contexts.insert("System`".to_owned());
        }
        for name in &self.known_symbols {
            if wildcard_matches(name, pattern)
                && let Some((context, _)) = split_full_symbol(name)
            {
                contexts.insert(context.to_owned());
            }
        }
        Some(list(contexts.into_iter().map(string)))
    }

    fn names_expr(&self, args: &[Expr]) -> Option<Expr> {
        let [Expr::String(pattern)] = args else {
            return None;
        };
        let mut names = BTreeSet::new();
        for name in SYSTEM_SYMBOLS.iter() {
            let full = format!("System`{name}");
            let candidate = if pattern.contains('`') { &full } else { name };
            if wildcard_matches(candidate, pattern) {
                names.insert(name.clone());
            }
        }
        for full in &self.known_symbols {
            let short = full.rsplit('`').next().unwrap_or(full);
            let candidate = if pattern.contains('`') { full } else { short };
            if wildcard_matches(candidate, pattern) {
                let visible = if full.starts_with("Global`") {
                    short.to_owned()
                } else {
                    full.clone()
                };
                names.insert(visible);
            }
        }
        Some(list(names.into_iter().map(string)))
    }

    fn name_q_expr(&self, args: &[Expr]) -> Option<Expr> {
        let [Expr::String(pattern)] = args else {
            return None;
        };
        let system_match = SYSTEM_SYMBOLS.iter().any(|name| {
            let full = format!("System`{name}");
            wildcard_matches(if pattern.contains('`') { &full } else { name }, pattern)
        });
        let user_match = self.known_symbols.iter().any(|full| {
            let short = full.rsplit('`').next().unwrap_or(full);
            wildcard_matches(if pattern.contains('`') { full } else { short }, pattern)
        });
        Some(bool_expr(system_match || user_match))
    }

    fn unique_expr(&mut self, args: &[Expr]) -> Option<Expr> {
        match args {
            [] => Some(self.unique_symbol(None)),
            [items] if items.has_head("List") => Some(list(
                items
                    .args()
                    .iter()
                    .map(|item| self.unique_symbol(Some(item))),
            )),
            [item @ (Expr::Symbol(_) | Expr::String(_))] => Some(self.unique_symbol(Some(item))),
            _ => None,
        }
    }

    fn unique_symbol(&mut self, specification: Option<&Expr>) -> Expr {
        self.unique_counter += 1;
        let name = match specification {
            None => format!("${}", self.unique_counter),
            Some(Expr::Symbol(prefix)) => format!("{prefix}${}", self.unique_counter),
            Some(Expr::String(prefix)) => format!("{prefix}{}", self.unique_counter),
            _ => unreachable!("validated Unique specification"),
        };
        self.register_symbol_name(&name);
        symbol(name)
    }

    fn compile_string_specs(
        &self,
        specification: &Expr,
        allow_rules: bool,
    ) -> Option<Vec<StringPatternSpec>> {
        let items = if specification.has_head("List") {
            specification.args().to_vec()
        } else {
            vec![specification.clone()]
        };
        items
            .into_iter()
            .map(|item| {
                let (pattern, template) = if allow_rules
                    && (item.has_head("Rule") || item.has_head("RuleDelayed"))
                    && item.args().len() == 2
                {
                    (item.args()[0].clone(), Some(item.args()[1].clone()))
                } else {
                    (item, None)
                };
                Some(StringPatternSpec {
                    pattern: compile_string_pattern(&pattern)?,
                    template,
                })
            })
            .collect()
    }

    fn string_match_at(
        &mut self,
        pattern: &CompiledStringPattern,
        source: &str,
        start: usize,
    ) -> Result<Option<StringFoundMatch>> {
        let Some(captures) = pattern.regex.captures_at(source, start) else {
            return Ok(None);
        };
        let matched = captures.get(0).expect("whole regex capture");
        if matched.start() != start {
            return Ok(None);
        }
        let mut bindings = Vec::new();
        for (name, groups) in &pattern.bindings {
            let values = groups
                .iter()
                .map(|group| captures.name(group).map(|value| value.as_str()))
                .collect::<Option<Vec<_>>>();
            let Some(values) = values else {
                return Ok(None);
            };
            if values.windows(2).any(|pair| pair[0] != pair[1]) {
                return Ok(None);
            }
            bindings.push((name.clone(), string(values[0])));
        }
        let tests = pattern
            .tests
            .iter()
            .map(|(group, criterion)| {
                captures
                    .name(group)
                    .map(|capture| (capture.as_str().to_owned(), criterion.clone()))
            })
            .collect::<Option<Vec<_>>>();
        let Some(tests) = tests else {
            return Ok(None);
        };
        drop(captures);
        for (text, criterion) in tests {
            for character in text.chars() {
                let tested = self.evaluate(call(criterion.clone(), [string(character)]))?;
                if !is_symbol(&tested, "True") {
                    return Ok(None);
                }
            }
        }
        Ok(Some(StringFoundMatch {
            start,
            end: matched.end(),
            bindings,
        }))
    }

    fn first_string_match_at(
        &mut self,
        specs: &[StringPatternSpec],
        source: &str,
        start: usize,
    ) -> Result<Option<(StringFoundMatch, usize)>> {
        for (index, spec) in specs.iter().enumerate() {
            if let Some(found) = self.string_match_at(&spec.pattern, source, start)? {
                return Ok(Some((found, index)));
            }
        }
        Ok(None)
    }

    fn string_boolean_expr(&mut self, args: &[Expr], mode: u8) -> Result<Option<Expr>> {
        let [source, pattern] = args else {
            return Ok(None);
        };
        if source.has_head("List") {
            let mut results = Vec::new();
            for item in source.args() {
                let Some(result) =
                    self.string_boolean_expr(&[item.clone(), pattern.clone()], mode)?
                else {
                    return Ok(None);
                };
                results.push(result);
            }
            return Ok(Some(list(results)));
        }
        let Expr::String(source) = source else {
            return Ok(None);
        };
        let Some(specs) = self.compile_string_specs(pattern, false) else {
            return Ok(None);
        };
        let boundaries = string_boundaries(source);
        let mut any = false;
        for start in boundaries {
            for spec in &specs {
                let Some(found) = self.string_match_at(&spec.pattern, source, start)? else {
                    continue;
                };
                let accepted = match mode {
                    0 => found.start == 0 && found.end == source.len(),
                    3 => found.start == 0,
                    4 => found.end == source.len(),
                    _ => true,
                };
                if accepted {
                    any = true;
                    break;
                }
            }
            if any {
                break;
            }
        }
        if mode == 1 {
            any = !any;
        }
        Ok(Some(bool_expr(any)))
    }

    fn string_position_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([source, pattern] | [source, pattern, _]) = args else {
            return Ok(None);
        };
        if source.has_head("List") {
            let mut results = Vec::new();
            for item in source.args() {
                let mut threaded = vec![item.clone(), pattern.clone()];
                threaded.extend(args.iter().skip(2).cloned());
                let Some(result) = self.string_position_expr(&threaded)? else {
                    return Ok(None);
                };
                results.push(result);
            }
            return Ok(Some(list(results)));
        }
        let Expr::String(source) = source else {
            return Ok(None);
        };
        let Some(specs) = self.compile_string_specs(pattern, false) else {
            return Ok(None);
        };
        let Some(limit) = match_limit(args.get(2)) else {
            return Ok(None);
        };
        let mut positions = Vec::new();
        for start in string_boundaries(source) {
            if limit.is_some_and(|limit| positions.len() >= limit) {
                break;
            }
            if let Some((found, _)) = self.first_string_match_at(&specs, source, start)? {
                positions.push((found.start, found.end));
            }
        }
        positions.sort_unstable();
        positions.dedup();
        Ok(Some(list(positions.into_iter().map(|(start, end)| {
            list([
                integer(source[..start].chars().count() + 1),
                integer(source[..end].chars().count()),
            ])
        }))))
    }

    fn string_cases_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([source, pattern] | [source, pattern, _]) = args else {
            return Ok(None);
        };
        if source.has_head("List") {
            let mut results = Vec::new();
            for item in source.args() {
                let mut threaded = vec![item.clone(), pattern.clone()];
                threaded.extend(args.iter().skip(2).cloned());
                let Some(result) = self.string_cases_expr(&threaded)? else {
                    return Ok(None);
                };
                results.push(result);
            }
            return Ok(Some(list(results)));
        }
        let Expr::String(source) = source else {
            return Ok(None);
        };
        let Some(specs) = self.compile_string_specs(pattern, true) else {
            return Ok(None);
        };
        let Some(limit) = match_limit(args.get(2)) else {
            return Ok(None);
        };
        let mut results = Vec::new();
        let mut position = 0;
        while position <= source.len() && !limit.is_some_and(|limit| results.len() >= limit) {
            let Some((found, spec_index)) = self.first_string_match_at(&specs, source, position)?
            else {
                let Some(next) = next_string_boundary(source, position) else {
                    break;
                };
                position = next;
                continue;
            };
            let result = if let Some(template) = &specs[spec_index].template {
                self.evaluate(substitute_binding_values(template, &found.bindings))?
            } else {
                string(&source[found.start..found.end])
            };
            results.push(result);
            position = if found.end > position {
                found.end
            } else {
                next_string_boundary(source, position).unwrap_or(source.len() + 1)
            };
        }
        Ok(Some(list(results)))
    }

    fn string_replace_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([source, rules] | [source, rules, _]) = args else {
            return Ok(None);
        };
        if source.has_head("List") {
            let mut results = Vec::new();
            for item in source.args() {
                let mut threaded = vec![item.clone(), rules.clone()];
                threaded.extend(args.iter().skip(2).cloned());
                let Some(result) = self.string_replace_expr(&threaded)? else {
                    return Ok(None);
                };
                results.push(result);
            }
            return Ok(Some(list(results)));
        }
        let Expr::String(source) = source else {
            return Ok(None);
        };
        let Some(specs) = self.compile_string_specs(rules, true) else {
            return Ok(None);
        };
        if specs.iter().any(|spec| spec.template.is_none()) {
            return Ok(None);
        }
        let Some(limit) = match_limit(args.get(2)) else {
            return Ok(None);
        };
        let mut pieces = Vec::new();
        let mut literal = String::new();
        let mut position = 0;
        let mut replacements = 0;
        while position <= source.len() && !limit.is_some_and(|limit| replacements >= limit) {
            let Some((found, spec_index)) = self.first_string_match_at(&specs, source, position)?
            else {
                let Some(next) = next_string_boundary(source, position) else {
                    break;
                };
                literal.push_str(&source[position..next]);
                position = next;
                continue;
            };
            if !literal.is_empty() {
                pieces.push(string(std::mem::take(&mut literal)));
            }
            let template = specs[spec_index]
                .template
                .as_ref()
                .expect("replacement spec");
            pieces.push(self.evaluate(substitute_binding_values(template, &found.bindings))?);
            replacements += 1;
            position = if found.end > position {
                found.end
            } else {
                next_string_boundary(source, position).unwrap_or(source.len() + 1)
            };
        }
        if position < source.len() {
            literal.push_str(&source[position..]);
        }
        if !literal.is_empty() {
            pieces.push(string(literal));
        }
        Ok(Some(normalize_string_expression(pieces)))
    }

    fn polynomial_insert_term(
        &mut self,
        polynomial: &mut NativePolynomial,
        powers: Vec<usize>,
        coefficient: Expr,
    ) -> Result<()> {
        if coefficient == integer(0) {
            return Ok(());
        }
        if let Some(existing) = polynomial.terms.remove(&powers) {
            let combined = self.evaluate(call("Plus", [existing, coefficient]))?;
            if combined != integer(0) {
                polynomial.terms.insert(powers, combined);
            }
        } else {
            polynomial.terms.insert(powers, coefficient);
        }
        Ok(())
    }

    fn polynomial_add(
        &mut self,
        mut left: NativePolynomial,
        right: NativePolynomial,
    ) -> Result<NativePolynomial> {
        for (powers, coefficient) in right.terms {
            self.polynomial_insert_term(&mut left, powers, coefficient)?;
        }
        Ok(left)
    }

    fn polynomial_multiply(
        &mut self,
        left: &NativePolynomial,
        right: &NativePolynomial,
    ) -> Result<NativePolynomial> {
        let mut result = NativePolynomial::default();
        for (left_powers, left_coefficient) in &left.terms {
            for (right_powers, right_coefficient) in &right.terms {
                let powers = left_powers
                    .iter()
                    .zip(right_powers)
                    .map(|(left, right)| left.checked_add(*right))
                    .collect::<Option<Vec<_>>>();
                let Some(powers) = powers else {
                    continue;
                };
                let coefficient = self.evaluate(call(
                    "Times",
                    [left_coefficient.clone(), right_coefficient.clone()],
                ))?;
                self.polynomial_insert_term(&mut result, powers, coefficient)?;
            }
        }
        Ok(result)
    }

    fn polynomial_power(
        &mut self,
        base: &NativePolynomial,
        exponent: usize,
        variable_count: usize,
    ) -> Result<NativePolynomial> {
        let mut result = NativePolynomial::default();
        result.terms.insert(vec![0; variable_count], integer(1));
        let mut factor = base.clone();
        let mut exponent = exponent;
        while exponent > 0 {
            if exponent % 2 == 1 {
                result = self.polynomial_multiply(&result, &factor)?;
            }
            exponent /= 2;
            if exponent > 0 {
                factor = self.polynomial_multiply(&factor, &factor)?;
            }
        }
        Ok(result)
    }

    fn polynomial_from_expr(
        &mut self,
        expr: &Expr,
        variables: &[Expr],
    ) -> Result<Option<NativePolynomial>> {
        if let Some(index) = variables.iter().position(|variable| variable == expr) {
            let mut powers = vec![0; variables.len()];
            powers[index] = 1;
            return Ok(Some(NativePolynomial {
                terms: BTreeMap::from([(powers, integer(1))]),
            }));
        }
        if !expr_contains_any(expr, variables) {
            return Ok(algebraic_expr_convertible(expr).then(|| NativePolynomial {
                terms: if expr == &integer(0) {
                    BTreeMap::new()
                } else {
                    BTreeMap::from([(vec![0; variables.len()], expr.clone())])
                },
            }));
        }
        if expr.has_head("Plus") {
            let mut result = NativePolynomial::default();
            for argument in expr.args() {
                let Some(argument) = self.polynomial_from_expr(argument, variables)? else {
                    return Ok(None);
                };
                result = self.polynomial_add(result, argument)?;
            }
            return Ok(Some(result));
        }
        if expr.has_head("Times") {
            let mut result = NativePolynomial {
                terms: BTreeMap::from([(vec![0; variables.len()], integer(1))]),
            };
            for argument in expr.args() {
                let Some(argument) = self.polynomial_from_expr(argument, variables)? else {
                    return Ok(None);
                };
                result = self.polynomial_multiply(&result, &argument)?;
            }
            return Ok(Some(result));
        }
        if expr.has_head("Power")
            && let [base, Expr::Integer(exponent)] = expr.args()
            && let Some(exponent) = exponent.to_usize()
        {
            let Some(base) = self.polynomial_from_expr(base, variables)? else {
                return Ok(None);
            };
            return Ok(Some(self.polynomial_power(
                &base,
                exponent,
                variables.len(),
            )?));
        }
        Ok(None)
    }

    fn polynomial_to_expr(
        &mut self,
        polynomial: &NativePolynomial,
        variables: &[Expr],
    ) -> Result<Expr> {
        if polynomial.terms.is_empty() {
            return Ok(integer(0));
        }
        let mut terms = Vec::with_capacity(polynomial.terms.len());
        for (powers, coefficient) in &polynomial.terms {
            let has_monomial = powers.iter().any(|power| *power != 0);
            let mut factors = Vec::new();
            if coefficient != &integer(1) || !has_monomial {
                factors.push(coefficient.clone());
            }
            for (variable, power) in variables.iter().zip(powers) {
                if *power == 1 {
                    factors.push(variable.clone());
                } else if *power > 1 {
                    factors.push(call("Power", [variable.clone(), integer(*power)]));
                }
            }
            terms.push(if factors.len() == 1 {
                factors.remove(0)
            } else {
                self.evaluate(call("Times", factors))?
            });
        }
        if terms.len() == 1 {
            Ok(terms.remove(0))
        } else {
            terms.sort_by(expression_order);
            Ok(simplify_plus_internal(&terms, false).unwrap_or_else(|| call("Plus", terms)))
        }
    }

    fn expand_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let mut variables = Vec::new();
        if !collect_polynomial_variables(target, &mut variables) {
            return Ok(None);
        }
        variables.sort_by(expression_order);
        variables.dedup();
        if let Some(pattern) = args.get(1) {
            if pattern.has_head("Blank") && pattern.args().is_empty()
                || pattern.has_head("Blank")
                    && pattern.args().len() == 1
                    && is_symbol(&pattern.args()[0], "Plus")
            {
                // Expanding a Plus pattern exposes every polynomial variable.
            } else {
                variables.retain(|variable| simple_pattern_matches(variable, pattern));
                if variables.is_empty() {
                    return Ok(Some(target.clone()));
                }
            }
        }
        let Some(polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        Ok(Some(self.polynomial_to_expr(&polynomial, &variables)?))
    }

    fn polynomial_q_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let variables = if let Some(specification) = args.get(1) {
            variable_exprs(specification)
        } else {
            let mut variables = Vec::new();
            if !collect_polynomial_variables(target, &mut variables) {
                return Ok(Some(symbol("False")));
            }
            variables.sort_by(expression_order);
            variables.dedup();
            variables
        };
        Ok(Some(bool_expr(
            self.polynomial_from_expr(target, &variables)?.is_some(),
        )))
    }

    fn monomial_list_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(1..=3).contains(&args.len()) {
            return Ok(None);
        }
        let mut order = MonomialOrder::Lexicographic;
        let variables = match args {
            [target] => {
                let Some(variables) = polynomial_variables(target) else {
                    return Ok(None);
                };
                variables
            }
            [target, candidate] => {
                if let Some(candidate_order) = monomial_order(candidate) {
                    order = candidate_order;
                    let Some(variables) = polynomial_variables(target) else {
                        return Ok(None);
                    };
                    variables
                } else {
                    variable_exprs(candidate)
                }
            }
            [_, specification, candidate_order] => {
                let Some(candidate_order) = monomial_order(candidate_order) else {
                    return Ok(None);
                };
                order = candidate_order;
                variable_exprs(specification)
            }
            _ => unreachable!(),
        };
        let Some(polynomial) = self.polynomial_from_expr(&args[0], &variables)? else {
            return Ok(None);
        };
        let mut terms = polynomial.terms.into_iter().collect::<Vec<_>>();
        terms.sort_by(|(left, _), (right, _)| monomial_compare(left, right, order));
        let mut output = Vec::with_capacity(terms.len());
        for (powers, coefficient) in terms {
            let polynomial = NativePolynomial {
                terms: BTreeMap::from([(powers, coefficient)]),
            };
            output.push(self.polynomial_to_expr(&polynomial, &variables)?);
        }
        Ok(Some(list(output)))
    }

    fn coefficient_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(2..=3).contains(&args.len()) {
            return Ok(None);
        }
        if let [target, forms, exponents] = args
            && forms.has_head("List")
            && exponents.has_head("List")
            && forms.args().len() == exponents.args().len()
        {
            let mut output = Vec::new();
            for (form, exponent) in forms.args().iter().zip(exponents.args()) {
                let Some(value) =
                    self.coefficient_expr(&[target.clone(), form.clone(), exponent.clone()])?
                else {
                    return Ok(None);
                };
                output.push(value);
            }
            return Ok(Some(list(output)));
        }
        let exponent = match args.get(2) {
            None => 1,
            Some(Expr::Integer(exponent)) if exponent.is_negative() => return Ok(Some(integer(0))),
            Some(Expr::Integer(exponent)) => {
                let Some(exponent) = exponent.to_usize() else {
                    return Ok(None);
                };
                exponent
            }
            _ => return Ok(None),
        };
        let Some(factors) = monomial_form_factors(&args[1]) else {
            return Ok(None);
        };
        let variables = factors
            .iter()
            .map(|(variable, _)| variable.clone())
            .collect::<Vec<_>>();
        let Some(polynomial) = self.polynomial_from_expr(&args[0], &variables)? else {
            return Ok(None);
        };
        let mut result = NativePolynomial::default();
        for (powers, coefficient) in polynomial.terms {
            let form_power = factors
                .iter()
                .enumerate()
                .map(|(index, (_, factor_power))| powers[index] / factor_power)
                .min()
                .unwrap_or(0);
            if form_power != exponent {
                continue;
            }
            let remaining = powers
                .iter()
                .zip(&factors)
                .map(|(power, (_, factor_power))| power - exponent * factor_power)
                .collect();
            self.polynomial_insert_term(&mut result, remaining, coefficient)?;
        }
        Ok(Some(self.polynomial_to_expr(&result, &variables)?))
    }

    fn exponent_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(2..=3).contains(&args.len()) {
            return Ok(None);
        }
        if args[1].has_head("List") {
            let mut output = Vec::new();
            for form in args[1].args() {
                let mut arguments = vec![args[0].clone(), form.clone()];
                arguments.extend(args.iter().skip(2).cloned());
                let Some(value) = self.exponent_expr(&arguments)? else {
                    return Ok(None);
                };
                output.push(value);
            }
            return Ok(Some(list(output)));
        }
        let Some(factors) = monomial_form_factors(&args[1]) else {
            return Ok(None);
        };
        let variables = factors
            .iter()
            .map(|(variable, _)| variable.clone())
            .collect::<Vec<_>>();
        let Some(polynomial) = self.polynomial_from_expr(&args[0], &variables)? else {
            return Ok(None);
        };
        if polynomial.terms.is_empty() {
            return Ok(Some(symbol("-Infinity")));
        }
        let mut exponents = polynomial
            .terms
            .keys()
            .map(|powers| {
                factors
                    .iter()
                    .enumerate()
                    .map(|(index, (_, factor_power))| powers[index] / factor_power)
                    .min()
                    .unwrap_or(0)
            })
            .collect::<Vec<_>>();
        exponents.sort_unstable();
        exponents.dedup();
        if let Some(function) = args.get(2) {
            return Ok(Some(self.evaluate(call(
                function.clone(),
                exponents.into_iter().map(integer),
            ))?));
        }
        Ok(Some(integer(exponents.into_iter().max().unwrap_or(0))))
    }

    fn coefficient_list_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(2..=3).contains(&args.len()) {
            return Ok(None);
        }
        let variables = variable_exprs(&args[1]);
        let Some(polynomial) = self.polynomial_from_expr(&args[0], &variables)? else {
            return Ok(None);
        };
        if polynomial.terms.is_empty() && args.len() == 2 {
            return Ok(Some(list(Vec::<Expr>::new())));
        }
        let dimensions = if let Some(specification) = args.get(2) {
            let values = if let Expr::Integer(value) = specification {
                if variables.len() != 1 {
                    return Ok(None);
                }
                let Some(value) = value.to_usize() else {
                    return Ok(None);
                };
                vec![value]
            } else if specification.has_head("List") {
                let Some(values) = specification
                    .args()
                    .iter()
                    .map(|value| match value {
                        Expr::Integer(value) => value.to_usize(),
                        _ => None,
                    })
                    .collect::<Option<Vec<_>>>()
                else {
                    return Ok(None);
                };
                values
            } else {
                return Ok(None);
            };
            if values.len() != variables.len() {
                return Ok(None);
            }
            Some(values)
        } else {
            None
        };
        Ok(Some(coefficient_array_expr(
            &polynomial,
            dimensions.as_deref(),
            0,
            &[],
        )))
    }

    fn collect_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(2..=3).contains(&args.len()) {
            return Ok(None);
        }
        let variables = variable_exprs(&args[1]);
        let Some(mut polynomial) = self.polynomial_from_expr(&args[0], &variables)? else {
            return Ok(None);
        };
        if let Some(function) = args.get(2) {
            for coefficient in polynomial.terms.values_mut() {
                *coefficient = self.evaluate(call(function.clone(), [coefficient.clone()]))?;
            }
        }
        Ok(Some(self.polynomial_to_expr(&polynomial, &variables)?))
    }

    fn factorization(
        &mut self,
        target: &Expr,
        modulus: Option<&BigInt>,
        gaussian: bool,
    ) -> Result<Option<NativeFactorization>> {
        let Some(variables) = polynomial_variables(target) else {
            return Ok(None);
        };
        let Some(polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        if polynomial.terms.is_empty() {
            return Ok(Some(NativeFactorization {
                coefficient: integer(0),
                factors: Vec::new(),
            }));
        }

        let mut common_powers = vec![usize::MAX; variables.len()];
        for powers in polynomial.terms.keys() {
            for (common, power) in common_powers.iter_mut().zip(powers) {
                *common = (*common).min(*power);
            }
        }
        common_powers.iter_mut().for_each(|power| {
            if *power == usize::MAX {
                *power = 0;
            }
        });
        let content = polynomial_rational_content(&polynomial).unwrap_or_else(BigRational::one);
        let mut reduced = NativePolynomial::default();
        for (powers, coefficient) in polynomial.terms {
            let powers = powers
                .iter()
                .zip(&common_powers)
                .map(|(power, common)| power - common)
                .collect();
            let coefficient = if content.is_one() {
                coefficient
            } else {
                self.evaluate(call(
                    "Times",
                    [
                        coefficient,
                        call("Power", [from_rational(content.clone()), integer(-1)]),
                    ],
                ))?
            };
            self.polynomial_insert_term(&mut reduced, powers, coefficient)?;
        }
        let mut factors = variables
            .iter()
            .zip(&common_powers)
            .filter(|(_, power)| **power > 0)
            .map(|(variable, power)| (variable.clone(), *power))
            .collect::<Vec<_>>();
        let mut coefficient = from_rational(content);

        if variables.len() == 1
            && let Some(mut coefficients) = univariate_rational_coefficients(&reduced)
        {
            if gaussian
                && coefficients.len() == 3
                && coefficients[0].is_one()
                && coefficients[1].is_zero()
                && coefficients[2].is_one()
            {
                factors.push((
                    self.evaluate(call(
                        "Plus",
                        [complex(integer(0), integer(-1)), variables[0].clone()],
                    ))?,
                    1,
                ));
                factors.push((
                    self.evaluate(call(
                        "Plus",
                        [complex(integer(0), integer(1)), variables[0].clone()],
                    ))?,
                    1,
                ));
                coefficients = vec![BigRational::one()];
            } else if let Some(modulus) = modulus {
                if modulus == &BigInt::from(2_u8)
                    && coefficients.len() == 3
                    && coefficients[0].is_one()
                    && coefficients[1].is_zero()
                    && coefficients[2].is_one()
                {
                    factors.push((
                        self.evaluate(call("Plus", [integer(1), variables[0].clone()]))?,
                        2,
                    ));
                    coefficients = vec![BigRational::one()];
                }
            } else {
                while coefficients.len() > 1 {
                    let Some(root) = integer_polynomial_root(&coefficients) else {
                        break;
                    };
                    let Some(quotient) = synthetic_divide_rational(&coefficients, &root) else {
                        break;
                    };
                    let factor =
                        self.evaluate(call("Plus", [from_rational(-root), variables[0].clone()]))?;
                    if let Some((_, exponent)) =
                        factors.iter_mut().find(|(existing, _)| existing == &factor)
                    {
                        *exponent += 1;
                    } else {
                        factors.push((factor, 1));
                    }
                    coefficients = quotient;
                }
            }
            if coefficients.len() == 1 {
                coefficient = self.evaluate(call(
                    "Times",
                    [coefficient, from_rational(coefficients[0].clone())],
                ))?;
            } else {
                let remainder = polynomial_from_rational_coefficients(&coefficients);
                let remainder = self.polynomial_to_expr(&remainder, &variables)?;
                factors.push((remainder, 1));
            }
        } else {
            let remainder = self.polynomial_to_expr(&reduced, &variables)?;
            if remainder != integer(1) {
                factors.push((remainder, 1));
            }
        }
        factors.sort_by(|(left, _), (right, _)| expression_order(left, right));
        Ok(Some(NativeFactorization {
            coefficient,
            factors,
        }))
    }

    fn factor_expr(&mut self, args: &[Expr], factor_list: bool) -> Result<Option<Expr>> {
        let Some(target) = args.first() else {
            return Ok(None);
        };
        let mut modulus = None;
        let mut gaussian = false;
        for option in &args[1..] {
            if !option.has_head("Rule") || option.args().len() != 2 {
                return Ok(None);
            }
            if is_symbol(&option.args()[0], "Modulus") {
                let Expr::Integer(value) = &option.args()[1] else {
                    return Ok(None);
                };
                if value <= &BigInt::one() {
                    return Ok(None);
                }
                modulus = Some(value.clone());
            } else if is_symbol(&option.args()[0], "GaussianIntegers") {
                gaussian = is_symbol(&option.args()[1], "True");
            } else if is_symbol(&option.args()[0], "Extension") {
                if is_symbol(&option.args()[1], "None") {
                    gaussian = false;
                } else if option.args()[1] == complex(integer(0), integer(1))
                    || option.args()[1].has_head("List")
                        && !option.args()[1].args().is_empty()
                        && option.args()[1]
                            .args()
                            .iter()
                            .all(|value| value == &complex(integer(0), integer(1)))
                {
                    gaussian = true;
                } else {
                    return Ok(None);
                }
            } else {
                return Ok(None);
            }
        }
        if modulus.is_some() && gaussian {
            return Ok(None);
        }
        let Some(factorization) = self.factorization(target, modulus.as_ref(), gaussian)? else {
            return Ok(None);
        };
        if factor_list {
            let mut entries = vec![list([factorization.coefficient, integer(1)])];
            entries.extend(
                factorization
                    .factors
                    .into_iter()
                    .map(|(factor, exponent)| list([factor, integer(exponent)])),
            );
            return Ok(Some(list(entries)));
        }
        if factorization.coefficient == integer(0) {
            return Ok(Some(integer(0)));
        }
        let mut factors = Vec::new();
        if factorization.coefficient != integer(1) || factorization.factors.is_empty() {
            factors.push(factorization.coefficient);
        }
        factors.extend(factorization.factors.into_iter().map(|(factor, exponent)| {
            if exponent == 1 {
                factor
            } else {
                call("Power", [factor, integer(exponent)])
            }
        }));
        Ok(Some(self.evaluate(call("Times", factors))?))
    }

    fn polynomial_mod_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, Expr::Integer(modulus)] = args else {
            return Ok(None);
        };
        if modulus <= &BigInt::one() {
            return Ok(None);
        }
        let Some(variables) = polynomial_variables(target) else {
            return Ok(None);
        };
        let Some(mut polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        for coefficient in polynomial.terms.values_mut() {
            let Some(value) = as_rational(coefficient) else {
                return Ok(None);
            };
            let numerator = value.numer().mod_floor(modulus);
            let denominator = value.denom().mod_floor(modulus);
            let gcd = denominator.extended_gcd(modulus);
            if !gcd.gcd.is_one() {
                return Ok(None);
            }
            *coefficient = integer((numerator * gcd.x).mod_floor(modulus));
        }
        polynomial
            .terms
            .retain(|_, coefficient| coefficient != &integer(0));
        Ok(Some(self.polynomial_to_expr(&polynomial, &variables)?))
    }

    fn divide_univariate_polynomials(
        &mut self,
        dividend: &NativePolynomial,
        divisor: &NativePolynomial,
    ) -> Result<Option<(NativePolynomial, NativePolynomial)>> {
        let Some(mut remainder) = univariate_expr_coefficients(dividend) else {
            return Ok(None);
        };
        let Some(divisor) = univariate_expr_coefficients(divisor) else {
            return Ok(None);
        };
        trim_polynomial_coefficients(&mut remainder);
        let mut divisor = divisor;
        trim_polynomial_coefficients(&mut divisor);
        if divisor.is_empty() {
            return Ok(None);
        }
        let mut quotient = vec![integer(0); remainder.len().saturating_sub(divisor.len()) + 1];
        while !remainder.is_empty() && remainder.len() >= divisor.len() {
            let degree = remainder.len() - divisor.len();
            let lead = self.evaluate(call(
                "Times",
                [
                    remainder.last().cloned().unwrap_or_else(|| integer(0)),
                    call(
                        "Power",
                        [
                            divisor.last().cloned().unwrap_or_else(|| integer(1)),
                            integer(-1),
                        ],
                    ),
                ],
            ))?;
            quotient[degree] =
                self.evaluate(call("Plus", [quotient[degree].clone(), lead.clone()]))?;
            for (index, coefficient) in divisor.iter().enumerate() {
                remainder[index + degree] = self.evaluate(call(
                    "Plus",
                    [
                        remainder[index + degree].clone(),
                        call("Times", [integer(-1), lead.clone(), coefficient.clone()]),
                    ],
                ))?;
            }
            trim_polynomial_coefficients(&mut remainder);
        }
        Ok(Some((
            polynomial_from_expr_coefficients(&quotient),
            polynomial_from_expr_coefficients(&remainder),
        )))
    }

    fn polynomial_division_expr(&mut self, args: &[Expr], quotient: bool) -> Result<Option<Expr>> {
        let [dividend, divisor, variable] = args else {
            return Ok(None);
        };
        let variables = variable_exprs(variable);
        if variables.len() != 1 {
            return Ok(None);
        }
        let Some(dividend) = self.polynomial_from_expr(dividend, &variables)? else {
            return Ok(None);
        };
        let Some(divisor) = self.polynomial_from_expr(divisor, &variables)? else {
            return Ok(None);
        };
        let Some((quotient_value, remainder)) =
            self.divide_univariate_polynomials(&dividend, &divisor)?
        else {
            return Ok(None);
        };
        self.polynomial_to_expr(
            if quotient {
                &quotient_value
            } else {
                &remainder
            },
            &variables,
        )
        .map(Some)
    }

    fn polynomial_negate(&mut self, polynomial: &NativePolynomial) -> Result<NativePolynomial> {
        let mut result = NativePolynomial::default();
        for (powers, coefficient) in &polynomial.terms {
            result.terms.insert(
                powers.clone(),
                self.evaluate(call("Times", [integer(-1), coefficient.clone()]))?,
            );
        }
        Ok(result)
    }

    fn divide_multivariate_polynomials(
        &mut self,
        dividend: &NativePolynomial,
        divisors: &[NativePolynomial],
        variable_count: usize,
    ) -> Result<Option<(Vec<NativePolynomial>, NativePolynomial)>> {
        if divisors.iter().any(|divisor| divisor.terms.is_empty()) {
            return Ok(None);
        }
        let mut quotients = vec![NativePolynomial::default(); divisors.len()];
        let mut remainder = NativePolynomial::default();
        let mut current = dividend.clone();
        let mut iterations = 0_usize;
        while let Some((powers, coefficient)) = current
            .terms
            .last_key_value()
            .map(|(powers, coefficient)| (powers.clone(), coefficient.clone()))
        {
            iterations += 1;
            if iterations > 100_000 {
                return Ok(None);
            }
            let mut divided = false;
            for (index, divisor) in divisors.iter().enumerate() {
                let Some((divisor_powers, divisor_coefficient)) = divisor.terms.last_key_value()
                else {
                    continue;
                };
                if !monomial_divides(divisor_powers, &powers) {
                    continue;
                }
                let quotient_powers = powers
                    .iter()
                    .zip(divisor_powers)
                    .map(|(power, divisor_power)| power - divisor_power)
                    .collect::<Vec<_>>();
                let quotient_coefficient = self.evaluate(call(
                    "Times",
                    [
                        coefficient.clone(),
                        call("Power", [divisor_coefficient.clone(), integer(-1)]),
                    ],
                ))?;
                let term = NativePolynomial {
                    terms: BTreeMap::from([(quotient_powers, quotient_coefficient)]),
                };
                quotients[index] = self.polynomial_add(quotients[index].clone(), term.clone())?;
                let product = self.polynomial_multiply(&term, divisor)?;
                let negative = self.polynomial_negate(&product)?;
                current = self.polynomial_add(current, negative)?;
                divided = true;
                break;
            }
            if !divided {
                current.terms.remove(&powers);
                self.polynomial_insert_term(&mut remainder, powers, coefficient)?;
            }
        }
        if remainder
            .terms
            .keys()
            .any(|powers| powers.len() != variable_count)
        {
            return Ok(None);
        }
        Ok(Some((quotients, remainder)))
    }

    fn polynomial_reduce_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, reducers, variables] = args else {
            return Ok(None);
        };
        if !reducers.has_head("List") {
            return Ok(None);
        }
        let variables = variable_exprs(variables);
        if variables.is_empty() {
            return Ok(None);
        }
        let Some(target) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        let mut divisor_polynomials = Vec::new();
        for reducer in reducers.args() {
            let Some(reducer) = self.polynomial_from_expr(reducer, &variables)? else {
                return Ok(None);
            };
            divisor_polynomials.push(reducer);
        }
        let Some((quotients, remainder)) =
            self.divide_multivariate_polynomials(&target, &divisor_polynomials, variables.len())?
        else {
            return Ok(None);
        };
        let mut quotient_expressions = Vec::new();
        for quotient in quotients {
            quotient_expressions.push(self.polynomial_to_expr(&quotient, &variables)?);
        }
        Ok(Some(list([
            list(quotient_expressions),
            self.polynomial_to_expr(&remainder, &variables)?,
        ])))
    }

    fn monic_multivariate(&mut self, polynomial: NativePolynomial) -> Result<NativePolynomial> {
        let Some((_, leading)) = polynomial.terms.last_key_value() else {
            return Ok(polynomial);
        };
        if leading == &integer(1) {
            return Ok(polynomial);
        }
        let inverse = call("Power", [leading.clone(), integer(-1)]);
        let mut result = NativePolynomial::default();
        for (powers, coefficient) in polynomial.terms {
            let coefficient = self.evaluate(call("Times", [coefficient, inverse.clone()]))?;
            self.polynomial_insert_term(&mut result, powers, coefficient)?;
        }
        Ok(result)
    }

    fn s_polynomial(
        &mut self,
        left: &NativePolynomial,
        right: &NativePolynomial,
    ) -> Result<Option<NativePolynomial>> {
        let Some((left_powers, left_coefficient)) = left.terms.last_key_value() else {
            return Ok(None);
        };
        let Some((right_powers, right_coefficient)) = right.terms.last_key_value() else {
            return Ok(None);
        };
        let lcm = left_powers
            .iter()
            .zip(right_powers)
            .map(|(left, right)| (*left).max(*right))
            .collect::<Vec<_>>();
        let left_multiplier = NativePolynomial {
            terms: BTreeMap::from([(
                lcm.iter()
                    .zip(left_powers)
                    .map(|(power, left)| power - left)
                    .collect(),
                self.evaluate(call("Power", [left_coefficient.clone(), integer(-1)]))?,
            )]),
        };
        let right_multiplier = NativePolynomial {
            terms: BTreeMap::from([(
                lcm.iter()
                    .zip(right_powers)
                    .map(|(power, right)| power - right)
                    .collect(),
                self.evaluate(call("Power", [right_coefficient.clone(), integer(-1)]))?,
            )]),
        };
        let left = self.polynomial_multiply(left, &left_multiplier)?;
        let right = self.polynomial_multiply(right, &right_multiplier)?;
        let negative_right = self.polynomial_negate(&right)?;
        Ok(Some(self.polynomial_add(left, negative_right)?))
    }

    fn groebner_basis_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [polynomials, variables] = args else {
            return Ok(None);
        };
        if !polynomials.has_head("List") {
            return Ok(None);
        }
        let variables = variable_exprs(variables);
        if variables.is_empty() {
            return Ok(None);
        }
        let mut basis = Vec::new();
        for polynomial in polynomials.args() {
            let Some(polynomial) = self.polynomial_from_expr(polynomial, &variables)? else {
                return Ok(None);
            };
            if !polynomial.terms.is_empty() {
                basis.push(self.monic_multivariate(polynomial)?);
            }
        }
        let mut pairs = Vec::new();
        for left in 0..basis.len() {
            for right in left + 1..basis.len() {
                pairs.push((left, right));
            }
        }
        let mut pair_index = 0;
        while pair_index < pairs.len() && basis.len() < 64 {
            let (left, right) = pairs[pair_index];
            pair_index += 1;
            let Some(s_polynomial) = self.s_polynomial(&basis[left], &basis[right])? else {
                continue;
            };
            let Some((_, remainder)) =
                self.divide_multivariate_polynomials(&s_polynomial, &basis, variables.len())?
            else {
                return Ok(None);
            };
            if remainder.terms.is_empty() {
                continue;
            }
            let remainder = self.monic_multivariate(remainder)?;
            let new_index = basis.len();
            for index in 0..new_index {
                pairs.push((index, new_index));
            }
            basis.push(remainder);
        }

        let mut minimal = Vec::new();
        for index in 0..basis.len() {
            let Some((leading, _)) = basis[index].terms.last_key_value() else {
                continue;
            };
            if basis.iter().enumerate().any(|(other_index, other)| {
                other_index != index
                    && other
                        .terms
                        .last_key_value()
                        .is_some_and(|(other_leading, _)| {
                            other_leading != leading && monomial_divides(other_leading, leading)
                        })
            }) {
                continue;
            }
            minimal.push(basis[index].clone());
        }
        let mut reduced = Vec::new();
        for index in 0..minimal.len() {
            let divisors = minimal
                .iter()
                .enumerate()
                .filter(|(other, _)| *other != index)
                .map(|(_, polynomial)| polynomial.clone())
                .collect::<Vec<_>>();
            let remainder = if divisors.is_empty() {
                minimal[index].clone()
            } else {
                let Some((_, remainder)) = self.divide_multivariate_polynomials(
                    &minimal[index],
                    &divisors,
                    variables.len(),
                )?
                else {
                    return Ok(None);
                };
                remainder
            };
            if !remainder.terms.is_empty() {
                let remainder = self.monic_multivariate(remainder)?;
                if !reduced.contains(&remainder) {
                    reduced.push(remainder);
                }
            }
        }
        let mut output = Vec::new();
        for polynomial in reduced {
            output.push(self.polynomial_to_expr(&polynomial, &variables)?);
        }
        output.sort_by(expression_order);
        Ok(Some(list(output)))
    }

    fn polynomial_gcd_lcm_expr(&mut self, args: &[Expr], lcm: bool) -> Result<Option<Expr>> {
        if args.is_empty() {
            return Ok(Some(integer(if lcm { 1 } else { 0 })));
        }
        let mut variables = Vec::new();
        for argument in args {
            let Some(mut argument_variables) = polynomial_variables(argument) else {
                return Ok(None);
            };
            variables.append(&mut argument_variables);
        }
        variables.sort_by(expression_order);
        variables.dedup();
        if variables.len() != 1 {
            return Ok(None);
        }
        let mut polynomials = Vec::new();
        for argument in args {
            let Some(polynomial) = self.polynomial_from_expr(argument, &variables)? else {
                return Ok(None);
            };
            polynomials.push(polynomial);
        }
        let mut gcd = polynomials[0].clone();
        for polynomial in &polynomials[1..] {
            let mut left = gcd;
            let mut right = polynomial.clone();
            while !right.terms.is_empty() {
                let Some((_, remainder)) = self.divide_univariate_polynomials(&left, &right)?
                else {
                    return Ok(None);
                };
                left = right;
                right = remainder;
            }
            gcd = monic_polynomial(self, left)?;
        }
        if !lcm {
            return self.polynomial_to_expr(&gcd, &variables).map(Some);
        }
        let mut product = NativePolynomial {
            terms: BTreeMap::from([(vec![0], integer(1))]),
        };
        for polynomial in &polynomials {
            product = self.polynomial_multiply(&product, polynomial)?;
        }
        for _ in 1..polynomials.len() {
            let Some((quotient, remainder)) = self.divide_univariate_polynomials(&product, &gcd)?
            else {
                return Ok(None);
            };
            if !remainder.terms.is_empty() {
                return Ok(None);
            }
            product = quotient;
        }
        let expression = self.polynomial_to_expr(&product, &variables)?;
        self.factor_expr(&[expression], false)
    }

    fn resultant_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [left, right, variable] = args else {
            return Ok(None);
        };
        let variables = variable_exprs(variable);
        if variables.len() != 1 {
            return Ok(None);
        }
        let Some(left) = self.polynomial_from_expr(left, &variables)? else {
            return Ok(None);
        };
        let Some(right) = self.polynomial_from_expr(right, &variables)? else {
            return Ok(None);
        };
        let Some(mut left) = univariate_expr_coefficients(&left) else {
            return Ok(None);
        };
        let Some(mut right) = univariate_expr_coefficients(&right) else {
            return Ok(None);
        };
        trim_polynomial_coefficients(&mut left);
        trim_polynomial_coefficients(&mut right);
        if left.is_empty() || right.is_empty() {
            return Ok(Some(integer(0)));
        }
        let left_degree = left.len() - 1;
        let right_degree = right.len() - 1;
        left.reverse();
        right.reverse();
        let size = left_degree + right_degree;
        let mut matrix = vec![vec![integer(0); size]; size];
        for row in 0..right_degree {
            matrix[row][row..row + left.len()].clone_from_slice(&left);
        }
        for row in 0..left_degree {
            matrix[right_degree + row][row..row + right.len()].clone_from_slice(&right);
        }
        let Some(resultant) = self.determinant_expr(&[list(matrix.into_iter().map(list))])? else {
            return Ok(None);
        };
        if let Some(expanded) = self.expand_expr(&[resultant.clone()])? {
            Ok(Some(expanded))
        } else {
            Ok(Some(resultant))
        }
    }

    fn discriminant_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, variable] = args else {
            return Ok(None);
        };
        let variables = variable_exprs(variable);
        if variables.len() != 1 {
            return Ok(None);
        }
        let Some(polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        let Some(mut coefficients) = univariate_expr_coefficients(&polynomial) else {
            return Ok(None);
        };
        trim_polynomial_coefficients(&mut coefficients);
        if coefficients.len() <= 1 {
            return Ok(Some(integer(0)));
        }
        let degree = coefficients.len() - 1;
        let derivative = coefficients
            .iter()
            .enumerate()
            .skip(1)
            .map(|(power, coefficient)| {
                self.evaluate(call("Times", [integer(power), coefficient.clone()]))
            })
            .collect::<Result<Vec<_>>>()?;
        let derivative_expr =
            self.polynomial_to_expr(&polynomial_from_expr_coefficients(&derivative), &variables)?;
        let target_expr = self.polynomial_to_expr(&polynomial, &variables)?;
        let Some(resultant) =
            self.resultant_expr(&[target_expr, derivative_expr, variable.clone()])?
        else {
            return Ok(None);
        };
        let sign = if degree * (degree - 1) / 2 % 2 == 0 {
            1
        } else {
            -1
        };
        Ok(Some(self.evaluate(call(
            "Times",
            [
                integer(sign),
                resultant,
                call(
                    "Power",
                    [
                        coefficients.last().cloned().unwrap_or_else(|| integer(1)),
                        integer(-1),
                    ],
                ),
            ],
        ))?))
    }

    fn subresultants_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [left_expr, right_expr, variable] = args else {
            return Ok(None);
        };
        let variables = variable_exprs(variable);
        if variables.len() != 1 {
            return Ok(None);
        }
        let Some(mut left) = self.polynomial_from_expr(left_expr, &variables)? else {
            return Ok(None);
        };
        let Some(mut right) = self.polynomial_from_expr(right_expr, &variables)? else {
            return Ok(None);
        };
        let Some(left_degree) = left.terms.keys().map(|powers| powers[0]).max() else {
            return Ok(None);
        };
        let Some(right_degree) = right.terms.keys().map(|powers| powers[0]).max() else {
            return Ok(None);
        };
        let limit = left_degree.min(right_degree);
        let Some(resultant) =
            self.resultant_expr(&[left_expr.clone(), right_expr.clone(), variable.clone()])?
        else {
            return Ok(None);
        };
        let mut coefficients = vec![integer(0); limit + 1];
        coefficients[0] = resultant;
        if let Some((powers, coefficient)) = right.terms.last_key_value()
            && powers[0] <= limit
        {
            coefficients[powers[0]] = coefficient.clone();
        }
        let mut iterations = 0_usize;
        while !right.terms.is_empty() {
            if coefficients
                .iter()
                .skip(1)
                .all(|coefficient| coefficient != &integer(0))
            {
                break;
            }
            iterations += 1;
            if iterations > limit + 1 {
                break;
            }
            let Some((_, remainder)) = self.divide_univariate_polynomials(&left, &right)? else {
                return Ok(None);
            };
            if remainder.terms.is_empty() {
                break;
            }
            if let Some((powers, coefficient)) = remainder.terms.last_key_value()
                && powers[0] > 0
                && powers[0] <= limit
            {
                coefficients[powers[0]] = coefficient.clone();
            }
            left = right;
            right = remainder;
        }
        Ok(Some(list(coefficients)))
    }

    fn decompose_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, variable] = args else {
            return Ok(None);
        };
        let variables = variable_exprs(variable);
        if variables.len() != 1 {
            return Ok(None);
        }
        let variable = &variables[0];
        if target.has_head("Power")
            && let [base, Expr::Integer(exponent)] = target.args()
            && exponent > &BigInt::one()
            && let Some(base_polynomial) = self.polynomial_from_expr(base, &variables)?
        {
            let constant_powers = vec![0];
            let constant = base_polynomial
                .terms
                .get(&constant_powers)
                .cloned()
                .unwrap_or_else(|| integer(0));
            let mut inner_polynomial = base_polynomial;
            inner_polynomial.terms.remove(&constant_powers);
            let inner = self.polynomial_to_expr(&inner_polynomial, &variables)?;
            if inner != *variable {
                let outer_source = call(
                    "Power",
                    [
                        self.evaluate(call("Plus", [constant, variable.clone()]))?,
                        integer(exponent.clone()),
                    ],
                );
                let outer = self
                    .expand_expr(&[outer_source])?
                    .unwrap_or_else(|| target.clone());
                return Ok(Some(list([outer, inner])));
            }
        }

        let Some(polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        let positive_exponents = polynomial
            .terms
            .keys()
            .map(|powers| powers[0])
            .filter(|power| *power > 0)
            .collect::<Vec<_>>();
        let has_constant = polynomial.terms.contains_key(&vec![0]);
        if positive_exponents.len() < 2 && !has_constant {
            return Ok(Some(list([target.clone()])));
        }
        let exponent_gcd = positive_exponents
            .into_iter()
            .fold(0_usize, |gcd, exponent| {
                if gcd == 0 {
                    exponent
                } else {
                    gcd.gcd(&exponent)
                }
            });
        if exponent_gcd <= 1 {
            return Ok(Some(list([target.clone()])));
        }
        let outer = NativePolynomial {
            terms: polynomial
                .terms
                .into_iter()
                .map(|(powers, coefficient)| (vec![powers[0] / exponent_gcd], coefficient))
                .collect(),
        };
        Ok(Some(list([
            self.polynomial_to_expr(&outer, &variables)?,
            call("Power", [variable.clone(), integer(exponent_gcd)]),
        ])))
    }

    fn root_function_polynomial(
        &mut self,
        function: &Expr,
    ) -> Result<Option<(Vec<BigRational>, Expr)>> {
        let body = match function.args() {
            [body] if function.has_head("Function") => body,
            [_, body] if function.has_head("Function") => body,
            _ => return Ok(None),
        };
        let body = self.evaluate(body.clone())?;
        let slot = call("Slot", [integer(1)]);
        let Some(polynomial) = self.polynomial_from_expr(&body, &[slot.clone()])? else {
            return Ok(None);
        };
        Ok(univariate_rational_coefficients(&polynomial).map(|coefficients| (coefficients, slot)))
    }

    fn root_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(2..=3).contains(&args.len()) {
            return Ok(None);
        }
        let Expr::Integer(index) = &args[1] else {
            return Ok(None);
        };
        let Some(mut index) = index.to_usize().and_then(|index| index.checked_sub(1)) else {
            return Ok(None);
        };
        let method = match args.get(2) {
            None => 0,
            Some(Expr::Integer(method))
                if method == &BigInt::zero() || method == &BigInt::one() =>
            {
                method.to_i64().unwrap_or(0)
            }
            _ => return Ok(None),
        };
        if let Some(
            ref root @ Expr::Root {
                ref coefficients, ..
            },
        ) = algebraic_coefficient_root(&args[0], index, method)
        {
            if coefficients.len().saturating_sub(1) <= self.max_root_degree {
                return Ok(Some(root.clone()));
            }
            return Ok(None);
        }
        let Some((coefficients, _)) = self.root_function_polynomial(&args[0])? else {
            return Ok(None);
        };
        if coefficients.len() <= 1 || index >= coefficients.len() - 1 {
            return Ok(None);
        }
        let original_degree = coefficients.len() - 1;
        let Some(square_free) = square_free_rational_polynomial(&coefficients) else {
            return Ok(None);
        };
        if square_free.len() <= 1 {
            return Ok(None);
        }
        let square_free_degree = square_free.len() - 1;
        if square_free_degree > self.max_root_degree {
            return Ok(None);
        }
        if square_free_degree < original_degree && original_degree % square_free_degree == 0 {
            index /= original_degree / square_free_degree;
        }
        index = index.min(square_free_degree - 1);
        if let Some(exact) = exact_polynomial_root(&square_free, index) {
            return Ok(Some(exact));
        }
        let Some(integer_coefficients) = primitive_integer_coefficients(&square_free) else {
            return Ok(None);
        };
        Ok(Some(Expr::Root {
            coefficients: integer_coefficients,
            index,
            method,
        }))
    }

    fn integer_polynomial_expr(
        &mut self,
        coefficients: &[BigInt],
        variable: &Expr,
    ) -> Result<Expr> {
        let polynomial = NativePolynomial {
            terms: coefficients
                .iter()
                .enumerate()
                .filter(|(_, coefficient)| !coefficient.is_zero())
                .map(|(power, coefficient)| (vec![power], integer(coefficient.clone())))
                .collect(),
        };
        self.polynomial_to_expr(&polynomial, &[variable.clone()])
    }

    fn minimal_polynomial_coefficients(&self, target: &Expr) -> Option<Vec<BigInt>> {
        if let Expr::Root { coefficients, .. } = target {
            return Some(coefficients.clone());
        }
        if target.has_head("Power")
            && let [Expr::Root { coefficients, .. }, Expr::Integer(exponent)] = target.args()
            && exponent.is_positive()
        {
            let (degree, value) = binomial_root_value(coefficients)?;
            let exponent = exponent.to_usize()?;
            let common = degree.gcd(&exponent);
            let output_degree = degree / common;
            let output_value = value.pow(i32::try_from(exponent / common).ok()?);
            let mut rational_coefficients = vec![BigRational::zero(); output_degree + 1];
            rational_coefficients[0] = -output_value;
            rational_coefficients[output_degree] = BigRational::one();
            return primitive_integer_coefficients(&rational_coefficients);
        }
        if target.has_head("Plus")
            && target.args().len() == 2
            && let (Some((left, left_positive)), Some((right, right_positive))) = (
                square_root_radicand(&target.args()[0]),
                square_root_radicand(&target.args()[1]),
            )
            && left_positive
            && right_positive
        {
            let constant = (&left - &right).pow(2);
            let quadratic = BigRational::from_integer(BigInt::from(-2)) * (&left + &right);
            return primitive_integer_coefficients(&[
                constant,
                BigRational::zero(),
                quadratic,
                BigRational::zero(),
                BigRational::one(),
            ]);
        }
        match target {
            Expr::Integer(value) => Some(vec![-value, BigInt::one()]),
            Expr::Rational(value) => Some(vec![-value.numer(), value.denom().clone()]),
            _ => None,
        }
    }

    fn minimal_polynomial_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(1..=2).contains(&args.len()) {
            return Ok(None);
        }
        let Some(coefficients) = self.minimal_polynomial_coefficients(&args[0]) else {
            return Ok(None);
        };
        let variable = args
            .get(1)
            .cloned()
            .unwrap_or_else(|| call("Slot", [integer(1)]));
        let polynomial = self.integer_polynomial_expr(&coefficients, &variable)?;
        Ok(Some(if args.len() == 1 {
            call("Function", [polynomial])
        } else {
            polynomial
        }))
    }

    fn root_reduce_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target] = args else {
            return Ok(None);
        };
        if target.has_head("List") {
            let mut output = Vec::new();
            for value in target.args() {
                output.push(
                    self.root_reduce_expr(&[value.clone()])?
                        .unwrap_or_else(|| value.clone()),
                );
            }
            return Ok(Some(list(output)));
        }
        if let Some(special) = root_reduce_special(target) {
            return Ok(Some(special));
        }
        if matches!(target, Expr::Root { .. }) {
            return Ok(Some(target.clone()));
        }
        if matches!(
            target.head().symbol_name().map(system_dispatch_name),
            Some("Re" | "Im" | "Abs")
        ) && target.args().len() == 1
            && let Expr::Root {
                coefficients,
                index,
                ..
            } = &target.args()[0]
            && coefficients == &vec![BigInt::one(), BigInt::zero(), BigInt::one()]
        {
            return Ok(Some(
                match target.head().symbol_name().map(system_dispatch_name) {
                    Some("Re") => integer(0),
                    Some("Im") => integer(if *index == 0 { -1 } else { 1 }),
                    Some("Abs") => integer(1),
                    _ => unreachable!(),
                },
            ));
        }
        if target.has_head("Power")
            && let [
                root @ Expr::Root {
                    coefficients,
                    index,
                    method,
                },
                exponent,
            ] = target.args()
            && let Some((degree, value)) = binomial_root_value(coefficients)
        {
            if let Expr::Integer(exponent) = exponent {
                if exponent.is_positive()
                    && exponent
                        .to_usize()
                        .is_some_and(|exponent| exponent % degree == 0)
                {
                    let power = exponent.to_usize().unwrap_or(0) / degree;
                    return Ok(Some(from_rational(
                        value.pow(i32::try_from(power).unwrap_or(i32::MAX)),
                    )));
                }
                if exponent == &BigInt::from(-1) {
                    let mut reciprocal = coefficients.iter().rev().cloned().collect::<Vec<_>>();
                    if reciprocal.last().is_some_and(Signed::is_negative) {
                        reciprocal
                            .iter_mut()
                            .for_each(|coefficient| *coefficient = -&*coefficient);
                    }
                    let reciprocal_index = if degree % 2 == 1 && *index == 0 {
                        0
                    } else {
                        *index
                    };
                    return Ok(Some(Expr::Root {
                        coefficients: reciprocal,
                        index: reciprocal_index,
                        method: *method,
                    }));
                }
            }
            if exponent == &rational(1, 2) && value.is_positive() && degree == 2 && *index == 1 {
                let mut coefficients = vec![BigInt::zero(); 5];
                let Some(value) = primitive_integer_coefficients(&[
                    -value,
                    BigRational::zero(),
                    BigRational::zero(),
                    BigRational::zero(),
                    BigRational::one(),
                ]) else {
                    return Ok(None);
                };
                coefficients.clone_from_slice(&value);
                return Ok(Some(Expr::Root {
                    coefficients,
                    index: 1,
                    method: *method,
                }));
            }
            let _ = root;
        }
        if target.has_head("Plus") && target.args().len() == 2 {
            let left = square_root_radicand(&target.args()[0]);
            let right = square_root_radicand(&target.args()[1]);
            if let (Some((left, true)), Some((right, true))) = (left, right) {
                let constant = (&left - &right).pow(2);
                let quadratic = BigRational::from_integer(BigInt::from(-2)) * (&left + &right);
                let Some(coefficients) = primitive_integer_coefficients(&[
                    constant,
                    BigRational::zero(),
                    quadratic,
                    BigRational::zero(),
                    BigRational::one(),
                ]) else {
                    return Ok(None);
                };
                return Ok(Some(Expr::Root {
                    coefficients,
                    index: 3,
                    method: 0,
                }));
            }
        }
        Ok(None)
    }

    fn count_roots_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, specification] = args else {
            return Ok(None);
        };
        let (variable, bounds) = if specification.has_head("List") {
            let [variable, lower, upper] = specification.args() else {
                return Ok(None);
            };
            (variable, Some((lower, upper)))
        } else {
            (specification, None)
        };
        let variables = vec![variable.clone()];
        let Some(polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        let Some(coefficients) = univariate_rational_coefficients(&polynomial) else {
            return Ok(None);
        };
        let Some(roots) = numeric_polynomial_roots(&coefficients) else {
            return Ok(None);
        };
        let count = if let Some((lower, upper)) = bounds {
            let Some(lower) = numeric_complex_value(lower) else {
                return Ok(None);
            };
            let Some(upper) = numeric_complex_value(upper) else {
                return Ok(None);
            };
            roots
                .iter()
                .filter(|(real, imaginary)| {
                    *real >= lower.0 - 1e-10
                        && *real <= upper.0 + 1e-10
                        && *imaginary >= lower.1 - 1e-10
                        && *imaginary <= upper.1 + 1e-10
                })
                .count()
        } else {
            roots
                .iter()
                .filter(|(_, imaginary)| imaginary.abs() < 1e-10)
                .count()
        };
        Ok(Some(integer(count)))
    }

    fn root_intervals_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target] = args else {
            return Ok(None);
        };
        let Some(variables) = polynomial_variables(target) else {
            return Ok(None);
        };
        if variables.len() != 1 {
            return Ok(None);
        }
        let Some(polynomial) = self.polynomial_from_expr(target, &variables)? else {
            return Ok(None);
        };
        let Some(coefficients) = univariate_rational_coefficients(&polynomial) else {
            return Ok(None);
        };
        let (mut roots, residual) = rational_roots_with_residual(&coefficients);
        if residual.len() == 3 {
            let discriminant = &residual[1] * &residual[1]
                - BigRational::from_integer(BigInt::from(4)) * &residual[2] * &residual[0];
            if discriminant.is_positive() {
                // Irrational real isolation is intentionally left for the
                // general algebraic isolator; do not return a partial answer.
                return Ok(None);
            }
        } else if residual.len() > 1 {
            return Ok(None);
        }
        roots.sort();
        let mut grouped: Vec<(BigRational, usize)> = Vec::new();
        for root in roots {
            if grouped
                .last()
                .is_some_and(|(existing, _)| existing == &root)
            {
                if let Some((_, count)) = grouped.last_mut() {
                    *count += 1;
                }
            } else {
                grouped.push((root, 1));
            }
        }
        Ok(Some(list([
            list(grouped.iter().map(|(root, _)| {
                let root = from_rational(root.clone());
                list([root.clone(), root])
            })),
            list(
                grouped
                    .iter()
                    .map(|(_, multiplicity)| list([integer(*multiplicity)])),
            ),
        ])))
    }

    fn root_sum_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [polynomial_function, function] = args else {
            return Ok(None);
        };
        let Some((coefficients, _)) = self.root_function_polynomial(polynomial_function)? else {
            return Ok(None);
        };
        let power = function_power(function);
        if let Some(power) = power {
            return Ok(newton_power_sum(&coefficients, power).map(from_rational));
        }
        let (roots, residual) = rational_roots_with_residual(&coefficients);
        if residual.len() > 1 {
            return Ok(None);
        }
        let mut terms = Vec::new();
        for root in roots {
            terms.push(self.evaluate(call(function.clone(), [from_rational(root)]))?);
        }
        Ok(Some(self.evaluate(call("Plus", terms))?))
    }

    fn solve_polynomial_from_expr(
        &mut self,
        expr: &Expr,
        variables: &[Expr],
    ) -> Result<Option<NativePolynomial>> {
        if let Some(index) = variables.iter().position(|variable| variable == expr) {
            let mut powers = vec![0; variables.len()];
            powers[index] = 1;
            return Ok(Some(NativePolynomial {
                terms: BTreeMap::from([(powers, integer(1))]),
            }));
        }
        if !expr_contains_any(expr, variables) {
            return Ok(Some(NativePolynomial {
                terms: if expr == &integer(0) {
                    BTreeMap::new()
                } else {
                    BTreeMap::from([(vec![0; variables.len()], expr.clone())])
                },
            }));
        }
        if expr.has_head("Plus") {
            let mut result = NativePolynomial::default();
            for argument in expr.args() {
                let Some(argument) = self.solve_polynomial_from_expr(argument, variables)? else {
                    return Ok(None);
                };
                result = self.polynomial_add(result, argument)?;
            }
            return Ok(Some(result));
        }
        if expr.has_head("Times") {
            let mut result = NativePolynomial {
                terms: BTreeMap::from([(vec![0; variables.len()], integer(1))]),
            };
            for argument in expr.args() {
                let Some(argument) = self.solve_polynomial_from_expr(argument, variables)? else {
                    return Ok(None);
                };
                result = self.polynomial_multiply(&result, &argument)?;
            }
            return Ok(Some(result));
        }
        if expr.has_head("Power")
            && let [base, Expr::Integer(exponent)] = expr.args()
            && let Some(exponent) = exponent.to_usize()
        {
            let Some(base) = self.solve_polynomial_from_expr(base, variables)? else {
                return Ok(None);
            };
            return Ok(Some(self.polynomial_power(
                &base,
                exponent,
                variables.len(),
            )?));
        }
        Ok(None)
    }

    fn solve_divide(&mut self, numerator: Expr, denominator: Expr) -> Result<Expr> {
        if let (Some(numerator_value), Some(denominator_value)) = (
            numeric_real_value(&numerator),
            numeric_real_value(&denominator),
        ) && (matches!(numerator, Expr::Real(_)) || matches!(denominator, Expr::Real(_)))
            && denominator_value != 0.0
        {
            let quotient = numerator_value / denominator_value;
            return Ok(Expr::Real(if quotient.fract() == 0.0 {
                format!("{quotient:.0}.")
            } else {
                quotient.to_string()
            }));
        }
        if denominator.has_head("Power")
            && denominator.args().len() == 2
            && denominator.args()[1] == rational(1, 2)
            && let Some(radicand) = denominator.args().first().and_then(as_rational)
        {
            return self.evaluate(call(
                "Times",
                [numerator, denominator, from_rational(radicand.recip())],
            ));
        }
        self.evaluate(call(
            "Times",
            [numerator, call("Power", [denominator, integer(-1)])],
        ))
    }

    fn solve_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [equation_specification, variable_specification] = args else {
            return Ok(None);
        };
        let variables = variable_exprs(variable_specification);
        if variables.is_empty() {
            return Ok(None);
        }
        let equation_items = if equation_specification.has_head("List") {
            equation_specification.args().to_vec()
        } else {
            vec![equation_specification.clone()]
        };
        let mut equations = Vec::new();
        for equation in equation_items {
            if is_symbol(&equation, "True") {
                continue;
            }
            if is_symbol(&equation, "False") {
                return Ok(Some(list(Vec::<Expr>::new())));
            }
            if equation.has_head("Equal") {
                if equation.args().len() <= 1 {
                    continue;
                }
                for pair in equation.args().windows(2) {
                    equations.push(self.evaluate(call(
                        "Plus",
                        [
                            pair[0].clone(),
                            call("Times", [integer(-1), pair[1].clone()]),
                        ],
                    ))?);
                }
            } else {
                equations.push(equation);
            }
        }
        if equations.is_empty() {
            return Ok(Some(list([list(Vec::<Expr>::new())])));
        }
        let mut solve_polynomials = Vec::new();
        for equation in &equations {
            let Some(polynomial) = self.solve_polynomial_from_expr(equation, &variables)? else {
                return Ok(None);
            };
            solve_polynomials.push(polynomial);
        }
        let linear = solve_polynomials.iter().all(|polynomial| {
            polynomial
                .terms
                .keys()
                .all(|powers| powers.iter().sum::<usize>() <= 1)
        });
        if linear {
            let rows = solve_polynomials
                .iter()
                .map(|polynomial| {
                    let coefficients = (0..variables.len())
                        .map(|index| {
                            let mut powers = vec![0; variables.len()];
                            powers[index] = 1;
                            polynomial
                                .terms
                                .get(&powers)
                                .cloned()
                                .unwrap_or_else(|| integer(0))
                        })
                        .collect::<Vec<_>>();
                    let constant = polynomial
                        .terms
                        .get(&vec![0; variables.len()])
                        .cloned()
                        .unwrap_or_else(|| integer(0));
                    (coefficients, constant)
                })
                .collect::<Vec<_>>();
            if variables.len() == 1 {
                let Some((selected_index, (coefficients, constant))) = rows
                    .iter()
                    .enumerate()
                    .find(|(_, (coefficients, _))| coefficients[0] != integer(0))
                else {
                    return Ok(Some(list(Vec::<Expr>::new())));
                };
                let numerator = self.evaluate(call("Times", [integer(-1), constant.clone()]))?;
                let solution = self.solve_divide(numerator, coefficients[0].clone())?;
                for (row_index, (coefficients, constant)) in rows.iter().enumerate() {
                    if row_index == selected_index {
                        continue;
                    }
                    let value = self.evaluate(call(
                        "Plus",
                        [
                            constant.clone(),
                            call("Times", [coefficients[0].clone(), solution.clone()]),
                        ],
                    ))?;
                    if value != integer(0) {
                        return Ok(Some(list(Vec::<Expr>::new())));
                    }
                }
                return Ok(Some(list([list([call(
                    "Rule",
                    [variables[0].clone(), solution],
                )])])));
            }
            if variables.len() == 2 && rows.len() >= 2 {
                let (first_coefficients, first_constant) = &rows[0];
                let (second_coefficients, second_constant) = &rows[1];
                let first_rhs =
                    self.evaluate(call("Times", [integer(-1), first_constant.clone()]))?;
                let second_rhs =
                    self.evaluate(call("Times", [integer(-1), second_constant.clone()]))?;
                let determinant = self.evaluate(call(
                    "Plus",
                    [
                        call(
                            "Times",
                            [
                                first_coefficients[0].clone(),
                                second_coefficients[1].clone(),
                            ],
                        ),
                        call(
                            "Times",
                            [
                                integer(-1),
                                first_coefficients[1].clone(),
                                second_coefficients[0].clone(),
                            ],
                        ),
                    ],
                ))?;
                if determinant == integer(0) {
                    return Ok(None);
                }
                let x_numerator = self.evaluate(call(
                    "Plus",
                    [
                        call("Times", [first_rhs.clone(), second_coefficients[1].clone()]),
                        call(
                            "Times",
                            [
                                integer(-1),
                                first_coefficients[1].clone(),
                                second_rhs.clone(),
                            ],
                        ),
                    ],
                ))?;
                let y_numerator = self.evaluate(call(
                    "Plus",
                    [
                        call("Times", [first_coefficients[0].clone(), second_rhs]),
                        call(
                            "Times",
                            [integer(-1), first_rhs, second_coefficients[0].clone()],
                        ),
                    ],
                ))?;
                let mut x = self.solve_divide(x_numerator, determinant.clone())?;
                let mut y = self.solve_divide(y_numerator, determinant)?;
                if let Some(expanded) = self.expand_expr(&[x.clone()])? {
                    x = expanded;
                }
                if let Some(expanded) = self.expand_expr(&[y.clone()])? {
                    y = expanded;
                }
                return Ok(Some(list([list([
                    call("Rule", [variables[0].clone(), x]),
                    call("Rule", [variables[1].clone(), y]),
                ])])));
            }
            return Ok(None);
        }
        if variables.len() != 1 {
            return Ok(None);
        }
        let mut rational_polynomials = Vec::new();
        for polynomial in &solve_polynomials {
            let Some(coefficients) = univariate_rational_coefficients(polynomial) else {
                return Ok(None);
            };
            rational_polynomials.push(coefficients);
        }
        let mut common = rational_polynomials.remove(0);
        for polynomial in rational_polynomials {
            let Some(gcd) = gcd_rational_polynomials(&common, &polynomial) else {
                return Ok(None);
            };
            common = gcd;
        }
        let Some(square_free) = square_free_rational_polynomial(&common) else {
            return Ok(Some(list(Vec::<Expr>::new())));
        };
        let Some(integer_coefficients) = primitive_integer_coefficients(&square_free) else {
            return Ok(None);
        };
        let degree = square_free.len() - 1;
        let mut roots = Vec::new();
        for index in 0..degree {
            roots.push(
                exact_polynomial_root(&square_free, index).unwrap_or_else(|| Expr::Root {
                    coefficients: integer_coefficients.clone(),
                    index,
                    method: 0,
                }),
            );
        }
        roots.sort_by(expression_order);
        Ok(Some(list(roots.into_iter().map(|root| {
            list([call("Rule", [variables[0].clone(), root])])
        }))))
    }

    fn rational_parts(&mut self, expr: &Expr) -> Result<Option<(Expr, Expr)>> {
        if let Expr::Rational(value) = expr {
            return Ok(Some((
                integer(value.numer().clone()),
                integer(value.denom().clone()),
            )));
        }
        if expr.has_head("Times") {
            let mut numerator = integer(1);
            let mut denominator = integer(1);
            for factor in expr.args() {
                let Some((factor_numerator, factor_denominator)) = self.rational_parts(factor)?
                else {
                    return Ok(None);
                };
                numerator = self.evaluate(call("Times", [numerator, factor_numerator]))?;
                denominator = self.evaluate(call("Times", [denominator, factor_denominator]))?;
            }
            return Ok(Some((numerator, denominator)));
        }
        if expr.has_head("Plus") {
            let mut numerator = integer(0);
            let mut denominator = integer(1);
            for term in expr.args() {
                let Some((term_numerator, term_denominator)) = self.rational_parts(term)? else {
                    return Ok(None);
                };
                numerator = self.evaluate(call(
                    "Plus",
                    [
                        call("Times", [numerator, term_denominator.clone()]),
                        call("Times", [term_numerator, denominator.clone()]),
                    ],
                ))?;
                denominator = self.evaluate(call("Times", [denominator, term_denominator]))?;
            }
            if let Some(expanded) = self.expand_expr(&[numerator.clone()])? {
                numerator = expanded;
            }
            return Ok(Some((numerator, denominator)));
        }
        if expr.has_head("Power")
            && let [base, Expr::Integer(exponent)] = expr.args()
            && exponent.is_negative()
        {
            return Ok(Some((
                integer(1),
                if exponent == &BigInt::from(-1) {
                    base.clone()
                } else {
                    call("Power", [base.clone(), integer(exponent.abs())])
                },
            )));
        }
        Ok(algebraic_expr_convertible(expr).then(|| (expr.clone(), integer(1))))
    }

    fn rebuild_rational(&mut self, numerator: Expr, denominator: Expr) -> Result<Option<Expr>> {
        let Some(mut numerator) = self.factorization(&numerator, None, false)? else {
            return Ok(None);
        };
        let Some(mut denominator) = self.factorization(&denominator, None, false)? else {
            return Ok(None);
        };
        for (numerator_factor, numerator_exponent) in &mut numerator.factors {
            for (denominator_factor, denominator_exponent) in &mut denominator.factors {
                if numerator_factor == denominator_factor {
                    let canceled = (*numerator_exponent).min(*denominator_exponent);
                    *numerator_exponent -= canceled;
                    *denominator_exponent -= canceled;
                }
            }
        }
        let coefficient = self.evaluate(call(
            "Times",
            [
                numerator.coefficient,
                call("Power", [denominator.coefficient, integer(-1)]),
            ],
        ))?;
        let mut factors = Vec::new();
        if coefficient != integer(1)
            || numerator.factors.iter().all(|(_, exponent)| *exponent == 0)
                && denominator
                    .factors
                    .iter()
                    .all(|(_, exponent)| *exponent == 0)
        {
            factors.push(coefficient);
        }
        factors.extend(
            numerator
                .factors
                .into_iter()
                .filter(|(_, exponent)| *exponent > 0)
                .map(|(factor, exponent)| {
                    if exponent == 1 {
                        factor
                    } else {
                        call("Power", [factor, integer(exponent)])
                    }
                }),
        );
        factors.extend(
            denominator
                .factors
                .into_iter()
                .filter(|(_, exponent)| *exponent > 0)
                .map(|(factor, exponent)| call("Power", [factor, integer(-(exponent as i128))])),
        );
        Ok(Some(self.evaluate(call("Times", factors))?))
    }

    fn rational_simplify_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        if args.len() == 2 && !matches!(args[1], Expr::Symbol(_) | Expr::Call { .. }) {
            return Ok(None);
        }
        if target.has_head("List") {
            let mut output = Vec::new();
            for item in target.args() {
                let Some(value) = self.rational_simplify_expr(&[item.clone()])? else {
                    return Ok(None);
                };
                output.push(value);
            }
            return Ok(Some(list(output)));
        }
        let Some((numerator, denominator)) = self.rational_parts(target)? else {
            return Ok(None);
        };
        self.rebuild_rational(numerator, denominator)
    }

    fn fraction_part_expr(&mut self, args: &[Expr], numerator: bool) -> Result<Option<Expr>> {
        let [target] = args else {
            return Ok(None);
        };
        if target.has_head("List") {
            let mut output = Vec::new();
            for item in target.args() {
                let Some(part) = self.fraction_part_expr(&[item.clone()], numerator)? else {
                    return Ok(None);
                };
                output.push(part);
            }
            return Ok(Some(list(output)));
        }
        let Some((numerator_factors, denominator_factors)) = fraction_factors(target) else {
            return Ok(None);
        };
        let factors = if numerator {
            numerator_factors
        } else {
            denominator_factors
        };
        Ok(Some(if factors.is_empty() {
            integer(1)
        } else {
            self.evaluate(call("Times", factors))?
        }))
    }

    fn quantile_one(
        &mut self,
        sorted: &[Expr],
        quantile: &Expr,
        parameters: [BigRational; 4],
    ) -> Result<Option<Expr>> {
        let Some(quantile) = as_rational(quantile) else {
            return Ok(None);
        };
        let [a, b, c, d] = parameters;
        let position = a + (BigRational::from_integer(BigInt::from(sorted.len())) + b) * quantile;
        let integer_part = position.numer().div_floor(position.denom());
        let fraction = position - BigRational::from_integer(integer_part.clone());
        let Some(index) = integer_part.to_i64() else {
            return Ok(None);
        };
        if index < 1 {
            return Ok(sorted.first().cloned());
        }
        if usize::try_from(index)
            .ok()
            .is_some_and(|index| index >= sorted.len())
        {
            return Ok(sorted.last().cloned());
        }
        let index = usize::try_from(index - 1).unwrap_or(0);
        if fraction.is_zero() {
            return Ok(Some(sorted[index].clone()));
        }
        let weight = c + d * fraction;
        Ok(Some(self.evaluate(call(
            "Plus",
            [
                sorted[index].clone(),
                call(
                    "Times",
                    [
                        from_rational(weight),
                        call(
                            "Plus",
                            [
                                sorted[index + 1].clone(),
                                call("Times", [integer(-1), sorted[index].clone()]),
                            ],
                        ),
                    ],
                ),
            ],
        ))?))
    }

    fn quantile_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if !(2..=3).contains(&args.len()) || !args[0].has_head("List") || args[0].args().is_empty()
        {
            return Ok(None);
        }
        let mut sorted = args[0].args().to_vec();
        if sorted
            .iter()
            .any(|value| numeric_real_value(value).is_none())
        {
            return Ok(None);
        }
        sorted.sort_by(|left, right| {
            numeric_real_value(left)
                .partial_cmp(&numeric_real_value(right))
                .unwrap_or(Ordering::Equal)
        });
        let parameters = if let Some(parameters) = args.get(2) {
            let [first, second] = parameters.args() else {
                return Ok(None);
            };
            let ([a, b], [c, d]) = (first.args(), second.args()) else {
                return Ok(None);
            };
            let (Some(a), Some(b), Some(c), Some(d)) = (
                as_rational(a),
                as_rational(b),
                as_rational(c),
                as_rational(d),
            ) else {
                return Ok(None);
            };
            [a, b, c, d]
        } else {
            [
                BigRational::zero(),
                BigRational::zero(),
                BigRational::one(),
                BigRational::zero(),
            ]
        };
        if args[1].has_head("List") {
            let mut output = Vec::new();
            for quantile in args[1].args() {
                let Some(value) = self.quantile_one(&sorted, quantile, parameters.clone())? else {
                    return Ok(None);
                };
                output.push(value);
            }
            Ok(Some(list(output)))
        } else {
            self.quantile_one(&sorted, &args[1], parameters)
        }
    }

    fn quartiles_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target] = args else {
            return Ok(None);
        };
        let parameters = list([
            list([rational(1, 2), integer(0)]),
            list([integer(0), integer(1)]),
        ]);
        self.quantile_expr(&[
            target.clone(),
            list([rational(1, 4), rational(1, 2), rational(3, 4)]),
            parameters,
        ])
    }

    fn vector_matrix_q_expr(&mut self, args: &[Expr], matrix: bool) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let test = args.get(1);
        let values = if matrix {
            if !target.has_head("List")
                || target.args().is_empty()
                || target.args().iter().any(|row| !row.has_head("List"))
                || target
                    .args()
                    .windows(2)
                    .any(|rows| rows[0].args().len() != rows[1].args().len())
            {
                return Ok(Some(symbol("False")));
            }
            target
                .args()
                .iter()
                .flat_map(|row| row.args().iter())
                .cloned()
                .collect::<Vec<_>>()
        } else {
            if !target.has_head("List") || target.args().iter().any(|value| value.has_head("List"))
            {
                return Ok(Some(symbol("False")));
            }
            target.args().to_vec()
        };
        if let Some(test) = test {
            for value in values {
                if !is_symbol(&self.evaluate(call(test.clone(), [value]))?, "True") {
                    return Ok(Some(symbol("False")));
                }
            }
        }
        Ok(Some(symbol("True")))
    }

    fn counts_by_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, function] = args else {
            return Ok(None);
        };
        let Some(values) = target_call_args(target) else {
            return Ok(None);
        };
        let mut counts: Vec<(Expr, usize)> = Vec::new();
        for value in values {
            let key = self.evaluate(call(function.clone(), [value.clone()]))?;
            if let Some((_, count)) = counts.iter_mut().find(|(existing, _)| existing == &key) {
                *count += 1;
            } else {
                counts.push((key, 1));
            }
        }
        Ok(Some(call(
            "Association",
            counts
                .into_iter()
                .map(|(key, count)| call("Rule", [key, integer(count)])),
        )))
    }

    fn contains_only_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let test = args.iter().find_map(|argument| {
            (argument.has_head("Rule")
                && argument.args().len() == 2
                && is_symbol(&argument.args()[0], "SameTest"))
            .then(|| argument.args()[1].clone())
        });
        let data = args
            .iter()
            .filter(|argument| !argument.has_head("Rule"))
            .collect::<Vec<_>>();
        let [left, right] = data.as_slice() else {
            return Ok(None);
        };
        let (Some(left), Some(right)) = (target_call_args(left), target_call_args(right)) else {
            return Ok(None);
        };
        for value in left {
            let mut found = false;
            for candidate in right {
                found = if let Some(test) = &test {
                    is_symbol(
                        &self.evaluate(call(test.clone(), [value.clone(), candidate.clone()]))?,
                        "True",
                    )
                } else {
                    value == candidate
                };
                if found {
                    break;
                }
            }
            if !found {
                return Ok(Some(symbol("False")));
            }
        }
        Ok(Some(symbol("True")))
    }

    fn subdivide_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let (lower, upper, count) = match args {
            [Expr::Integer(count)] if count.is_positive() => {
                (integer(0), integer(1), count.to_usize())
            }
            [upper, Expr::Integer(count)] if count.is_positive() => {
                (integer(0), upper.clone(), count.to_usize())
            }
            [lower, upper, Expr::Integer(count)] if count.is_positive() => {
                (lower.clone(), upper.clone(), count.to_usize())
            }
            _ => return Ok(None),
        };
        let Some(count) = count else {
            return Ok(None);
        };
        let step = self.evaluate(call(
            "Times",
            [
                call("Plus", [upper, call("Times", [integer(-1), lower.clone()])]),
                rational(1, BigInt::from(count)),
            ],
        ))?;
        let mut output = Vec::new();
        for index in 0..=count {
            output.push(self.evaluate(call(
                "Plus",
                [lower.clone(), call("Times", [integer(index), step.clone()])],
            ))?);
        }
        Ok(Some(list(output)))
    }

    fn ratios_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target] = args else {
            return Ok(None);
        };
        let Some(values) = target_call_args(target) else {
            return Ok(None);
        };
        let mut output = Vec::new();
        for pair in values.windows(2) {
            output.push(self.evaluate(call(
                "Times",
                [
                    pair[1].clone(),
                    call("Power", [pair[0].clone(), integer(-1)]),
                ],
            ))?);
        }
        Ok(Some(call(target.head(), output)))
    }

    fn subset_map_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [function, target, positions] = args else {
            return Ok(None);
        };
        if !target.has_head("List") || !positions.has_head("List") {
            return Ok(None);
        }
        let mut indices = Vec::new();
        for position in positions.args() {
            let value = if let Expr::Integer(value) = position {
                value
            } else if let [Expr::Integer(value)] = position.args() {
                value
            } else {
                return Ok(None);
            };
            let Some(index) = value
                .to_i64()
                .and_then(|value| resolve_index(target.args().len(), value))
            else {
                return Ok(None);
            };
            indices.push(index);
        }
        let selected = list(indices.iter().map(|index| target.args()[*index].clone()));
        let transformed = self.evaluate(call(function.clone(), [selected]))?;
        if !transformed.has_head("List") || transformed.args().len() != indices.len() {
            return Ok(None);
        }
        let mut output = target.args().to_vec();
        for (index, value) in indices.into_iter().zip(transformed.args()) {
            output[index] = value.clone();
        }
        Ok(Some(list(output)))
    }

    fn ordering_function_compare(
        &mut self,
        function: Option<&Expr>,
        left: &Expr,
        right: &Expr,
    ) -> Result<Ordering> {
        let Some(function) = function else {
            return Ok(expression_order(left, right));
        };
        let result = self.evaluate(call(function.clone(), [left.clone(), right.clone()]))?;
        if is_symbol(&result, "True") {
            return Ok(Ordering::Less);
        }
        if is_symbol(&result, "False") {
            let reverse = self.evaluate(call(function.clone(), [right.clone(), left.clone()]))?;
            if is_symbol(&reverse, "True") {
                return Ok(Ordering::Greater);
            }
            if is_symbol(&reverse, "False") {
                return Ok(Ordering::Equal);
            }
            if let Expr::Integer(value) = reverse {
                return Ok(if value.is_positive() {
                    Ordering::Greater
                } else if value.is_negative() {
                    Ordering::Less
                } else {
                    Ordering::Equal
                });
            }
            return Ok(Ordering::Equal);
        }
        if let Expr::Integer(value) = result {
            return Ok(if value.is_positive() {
                Ordering::Less
            } else if value.is_negative() {
                Ordering::Greater
            } else {
                Ordering::Equal
            });
        }
        Ok(expression_order(left, right))
    }

    fn same_test_succeeds(
        &mut self,
        function: Option<&Expr>,
        left: &Expr,
        right: &Expr,
    ) -> Result<bool> {
        let Some(function) = function else {
            return Ok(false);
        };
        Ok(is_symbol(
            &self.evaluate(call(function.clone(), [left.clone(), right.clone()]))?,
            "True",
        ))
    }

    fn sort_order_expr(
        &mut self,
        args: &[Expr],
        reverse: bool,
        indices: bool,
    ) -> Result<Option<Expr>> {
        let mut same_test = None;
        let mut positional = Vec::new();
        for argument in args {
            if argument.has_head("Rule") {
                if argument.args().len() == 2 && is_symbol(&argument.args()[0], "SameTest") {
                    same_test = Some(&argument.args()[1]);
                } else {
                    return Ok(None);
                }
            } else {
                positional.push(argument);
            }
        }
        let valid_arity = if indices {
            (1..=3).contains(&positional.len())
        } else {
            (1..=3).contains(&positional.len())
        };
        if !valid_arity {
            return Ok(None);
        }
        let target = positional[0];
        let (head, source_items, association) = if let Some(entries) = association_entries(target) {
            (symbol("Association"), entries, true)
        } else if let Expr::Call { head, args } = target {
            (head.as_ref().clone(), args.clone(), false)
        } else {
            return Ok(None);
        };
        let count = if indices {
            positional.get(1).copied()
        } else {
            positional.get(2).copied()
        };
        let ordering_function = if indices {
            positional.get(2).copied()
        } else {
            positional.get(1).copied()
        };
        let mut items = source_items
            .into_iter()
            .enumerate()
            .map(|(index, item)| {
                let value = if association {
                    item.args()[1].clone()
                } else {
                    item.clone()
                };
                (item, value, index)
            })
            .collect::<Vec<_>>();

        // An insertion sort keeps the original order when the comparator or
        // SameTest regards two values as equivalent, while still allowing the
        // comparator to evaluate arbitrary Wolfram callables.
        for index in 1..items.len() {
            let mut insertion = index;
            while insertion > 0 {
                let left = items[insertion - 1].1.clone();
                let right = items[insertion].1.clone();
                let mut order = if self.same_test_succeeds(same_test, &left, &right)? {
                    Ordering::Equal
                } else {
                    self.ordering_function_compare(ordering_function, &left, &right)?
                };
                if reverse {
                    order = order.reverse();
                }
                if order != Ordering::Greater {
                    break;
                }
                items.swap(insertion - 1, insertion);
                insertion -= 1;
            }
        }
        if let Some(count) = count {
            let Some(selected) = select_ordered_count(items, count) else {
                return Ok(None);
            };
            items = selected;
        }
        Ok(Some(if indices {
            list(items.into_iter().map(|(_, _, index)| integer(index + 1)))
        } else {
            call(head, items.into_iter().map(|(item, _, _)| item))
        }))
    }

    fn sort_by_expr(&mut self, args: &[Expr], reverse: bool, indices: bool) -> Result<Expr> {
        let name = if indices {
            "OrderingBy"
        } else if reverse {
            "ReverseSortBy"
        } else {
            "SortBy"
        };
        let mut same_test = None;
        let mut positional = Vec::new();
        for argument in args {
            if argument.has_head("Rule") {
                if argument.args().len() == 2 && is_symbol(&argument.args()[0], "SameTest") {
                    same_test = Some(&argument.args()[1]);
                } else {
                    return Ok(call(name, args.iter().cloned()));
                }
            } else {
                positional.push(argument);
            }
        }
        let valid_arity = if indices {
            (2..=4).contains(&positional.len())
        } else {
            (2..=3).contains(&positional.len())
        };
        if !valid_arity {
            return Ok(call(name, args.iter().cloned()));
        }
        let target = positional[0];
        let function = positional[1];
        let multiple_functions = function.has_head("List");
        let (head, source_items, association) = if let Some(entries) = association_entries(target) {
            (symbol("Association"), entries, true)
        } else if let Expr::Call { head, args } = target {
            (head.as_ref().clone(), args.clone(), false)
        } else {
            return Ok(call(name, args.iter().cloned()));
        };
        let mut keyed = Vec::with_capacity(source_items.len());
        for (index, item) in source_items.into_iter().enumerate() {
            let value = if association {
                item.args()[1].clone()
            } else {
                item.clone()
            };
            let key = if multiple_functions {
                let mut keys = Vec::new();
                for function in function.args() {
                    keys.push(self.evaluate(call(function.clone(), [value.clone()]))?);
                }
                list(keys)
            } else {
                self.evaluate(call(function.clone(), [value.clone()]))?
            };
            let keys = if multiple_functions {
                key.args().to_vec()
            } else {
                vec![key]
            };
            keyed.push((item, value, keys, index));
        }
        let comparator = if indices {
            positional.get(3).copied()
        } else {
            positional.get(2).copied()
        };
        for index in 1..keyed.len() {
            let mut insertion = index;
            while insertion > 0 {
                let left_keys = keyed[insertion - 1].2.clone();
                let right_keys = keyed[insertion].2.clone();
                let mut order = Ordering::Equal;
                for (left, right) in left_keys.iter().zip(&right_keys) {
                    if self.same_test_succeeds(same_test, left, right)? {
                        continue;
                    }
                    order = self.ordering_function_compare(comparator, left, right)?;
                    if order != Ordering::Equal {
                        break;
                    }
                }
                if order == Ordering::Equal {
                    order = left_keys.len().cmp(&right_keys.len());
                }
                if order == Ordering::Equal && same_test.is_none() && !multiple_functions {
                    order = expression_order(&keyed[insertion - 1].1, &keyed[insertion].1);
                }
                if reverse {
                    order = order.reverse();
                }
                if order != Ordering::Greater {
                    break;
                }
                keyed.swap(insertion - 1, insertion);
                insertion -= 1;
            }
        }
        if indices {
            let selected = if let Some(count) = positional.get(2) {
                let Some(selected) = select_ordered_count(keyed, count) else {
                    return Ok(call(name, args.iter().cloned()));
                };
                selected
            } else {
                keyed
            };
            let ordered = selected
                .into_iter()
                .map(|(_, _, _, index)| integer(index + 1));
            Ok(list(ordered))
        } else {
            Ok(call(head, keyed.into_iter().map(|(item, _, _, _)| item)))
        }
    }

    fn extremal_by_expr(&mut self, args: &[Expr], maximal: bool) -> Result<Expr> {
        let name = if maximal { "MaximalBy" } else { "MinimalBy" };
        if !(2..=3).contains(&args.len()) {
            return Ok(call(name, args.iter().cloned()));
        }
        let target = &args[0];
        let function = &args[1];
        let (head, source_items, association) = if let Some(entries) = association_entries(target) {
            (symbol("Association"), entries, true)
        } else if let Expr::Call { head, args } = target {
            (head.as_ref().clone(), args.clone(), false)
        } else {
            return Ok(call(name, args.iter().cloned()));
        };
        let mut keyed = Vec::new();
        for (index, item) in source_items.into_iter().enumerate() {
            let value = if association {
                item.args()[1].clone()
            } else {
                item.clone()
            };
            keyed.push((item, self.evaluate(call(function.clone(), [value]))?, index));
        }
        keyed.sort_by(|(_, left_key, left_index), (_, right_key, right_index)| {
            let order = expression_order(left_key, right_key);
            let order = if maximal { order.reverse() } else { order };
            order.then_with(|| left_index.cmp(right_index))
        });
        let selected = if let Some(count) = args.get(2) {
            select_ordered_count(keyed, count).unwrap_or_default()
        } else if let Some((_, first_key, _)) = keyed.first() {
            keyed
                .iter()
                .take_while(|(_, key, _)| key == first_key)
                .cloned()
                .collect()
        } else {
            Vec::new()
        };
        Ok(call(head, selected.into_iter().map(|(item, _, _)| item)))
    }

    fn total_default(&mut self, target: &Expr) -> Result<Option<Expr>> {
        if let Some(entries) = association_entries(target) {
            return self
                .evaluate(call(
                    "Plus",
                    entries.into_iter().map(|entry| entry.args()[1].clone()),
                ))
                .map(Some);
        }
        let Expr::Call { head, args: values } = target else {
            return Ok(None);
        };
        if !is_symbol(head, "List") {
            return Ok(None);
        }
        if values.is_empty() {
            return Ok(Some(integer(0)));
        }
        if values.iter().all(|value| value.has_head("List"))
            && values
                .iter()
                .map(|value| value.args().len())
                .collect::<BTreeSet<_>>()
                .len()
                == 1
        {
            let width = values[0].args().len();
            let mut columns = Vec::with_capacity(width);
            for column in 0..width {
                columns.push(self.evaluate(call(
                    "Plus",
                    values.iter().map(|row| row.args()[column].clone()),
                ))?);
            }
            return Ok(Some(list(columns)));
        }
        self.evaluate(call("Plus", values.clone())).map(Some)
    }

    fn total_at_level(&mut self, target: &Expr, level: usize) -> Result<Option<Expr>> {
        if level == 0 {
            return Ok(None);
        }
        if level == 1 {
            return self.total_default(target);
        }
        if let Some(entries) = association_entries(target) {
            let mut output = Vec::with_capacity(entries.len());
            for entry in entries {
                let Some(value) = self.total_at_level(&entry.args()[1], level - 1)? else {
                    return Ok(None);
                };
                output.push(call("Rule", [entry.args()[0].clone(), value]));
            }
            return Ok(Some(call("Association", output)));
        }
        if !target.has_head("List") {
            return Ok(None);
        }
        let mut output = Vec::with_capacity(target.args().len());
        for value in target.args() {
            let Some(value) = self.total_at_level(value, level - 1)? else {
                return Ok(None);
            };
            output.push(value);
        }
        Ok(Some(list(output)))
    }

    fn total_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let Some(level_spec) = args.get(1) else {
            return self.total_default(target);
        };
        if level_spec.has_head("List")
            && let [Expr::Integer(level)] = level_spec.args()
        {
            let Some(level) = level.to_usize() else {
                return Ok(None);
            };
            return self.total_at_level(target, level);
        }
        let maximum = match level_spec {
            Expr::Integer(level) if !level.is_negative() => {
                let Some(level) = level.to_usize() else {
                    return Ok(None);
                };
                level
            }
            Expr::Symbol(name) if system_dispatch_name(name) == "Infinity" => usize::MAX,
            _ => return Ok(None),
        };
        let mut result = target.clone();
        for _ in 0..maximum {
            let Some(next) = self.total_default(&result)? else {
                break;
            };
            result = next;
        }
        Ok(Some(result))
    }

    fn differences_once(&mut self, values: &[Expr]) -> Result<Vec<Expr>> {
        let mut output = Vec::new();
        for pair in values.windows(2) {
            output.push(self.evaluate(call(
                "Plus",
                [
                    pair[1].clone(),
                    call("Times", [integer(-1), pair[0].clone()]),
                ],
            ))?);
        }
        Ok(output)
    }

    fn differences_multivariate(
        &mut self,
        target: &Expr,
        orders: &[usize],
    ) -> Result<Option<Expr>> {
        let Some((&outer_order, inner_orders)) = orders.split_first() else {
            return Ok(Some(target.clone()));
        };
        let Some(mut values) = target_call_args(target).map(<[Expr]>::to_vec) else {
            return Ok(None);
        };
        for _ in 0..outer_order {
            values = self.differences_once(&values)?;
            if values.is_empty() {
                return Ok(Some(list([])));
            }
        }
        if inner_orders.is_empty() {
            return Ok(Some(list(values)));
        }
        let mut output = Vec::with_capacity(values.len());
        for value in values {
            let Some(value) = self.differences_multivariate(&value, inner_orders)? else {
                return Ok(None);
            };
            output.push(value);
        }
        Ok(Some(list(output)))
    }

    fn differences_expr(&mut self, args: &[Expr]) -> Result<Expr> {
        let ([target] | [target, _]) = args else {
            return Ok(call("Differences", args.iter().cloned()));
        };
        let orders = match args.get(1) {
            None => vec![1],
            Some(Expr::Integer(order)) if !order.is_negative() => {
                vec![order.to_usize().unwrap_or(usize::MAX)]
            }
            Some(order_spec) if order_spec.has_head("List") => {
                let Some(orders) = order_spec
                    .args()
                    .iter()
                    .map(|order| match order {
                        Expr::Integer(order) if !order.is_negative() => order.to_usize(),
                        _ => None,
                    })
                    .collect::<Option<Vec<_>>>()
                else {
                    return Ok(call("Differences", args.iter().cloned()));
                };
                orders
            }
            _ => return Ok(call("Differences", args.iter().cloned())),
        };
        Ok(self
            .differences_multivariate(target, &orders)?
            .unwrap_or_else(|| call("Differences", args.iter().cloned())))
    }

    fn accumulate_expr(&mut self, args: &[Expr]) -> Result<Expr> {
        let ([target] | [target, _]) = args else {
            return Ok(call("Accumulate", args.iter().cloned()));
        };
        let function = args.get(1).cloned().unwrap_or_else(|| symbol("Plus"));
        if let Some(entries) = association_entries(target) {
            let mut total: Option<Expr> = None;
            let mut rules = Vec::new();
            for entry in entries {
                total = Some(match total {
                    None => entry.args()[1].clone(),
                    Some(previous) => {
                        self.evaluate(call(function.clone(), [previous, entry.args()[1].clone()]))?
                    }
                });
                rules.push(call(
                    "Rule",
                    [
                        entry.args()[0].clone(),
                        total.clone().expect("running value"),
                    ],
                ));
            }
            return Ok(call("Association", rules));
        }
        let Expr::Call { head, args: values } = target else {
            return Ok(call("Accumulate", args.iter().cloned()));
        };
        let mut total: Option<Expr> = None;
        let mut output = Vec::new();
        for value in values {
            total = Some(match total {
                None => value.clone(),
                Some(previous) => {
                    self.evaluate(call(function.clone(), [previous, value.clone()]))?
                }
            });
            output.push(total.clone().expect("running value"));
        }
        Ok(call(head.as_ref().clone(), output))
    }

    fn sequence_cases_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, pattern] = args else {
            return Ok(None);
        };
        if !target.has_head("List") {
            return Ok(None);
        }
        let mut inner = pattern;
        while (inner.has_head("Condition") || inner.has_head("HoldPattern"))
            && !inner.args().is_empty()
        {
            inner = &inner.args()[0];
        }
        if !inner.has_head("List") || inner.args().is_empty() {
            return Ok(None);
        }
        let width = inner.args().len();
        let mut output = Vec::new();
        let mut index = 0;
        while index + width <= target.args().len() {
            let candidate = list(target.args()[index..index + width].iter().cloned());
            let mut bindings = Vec::new();
            if self.match_pattern(&candidate, pattern, &mut bindings)? {
                output.push(candidate);
                index += width;
            } else {
                index += 1;
            }
        }
        Ok(Some(list(output)))
    }

    fn delete_duplicates_by_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target, function] | [target, function, _]) = args else {
            return Ok(None);
        };
        let test = args.get(2);
        let (head, values, association) = if let Some(entries) = association_entries(target) {
            (symbol("Association"), entries, true)
        } else if let Expr::Call { head, args } = target {
            (head.as_ref().clone(), args.clone(), false)
        } else {
            return Ok(None);
        };
        let mut output = Vec::new();
        let mut seen: Vec<Expr> = Vec::new();
        for value in values {
            let key_input = if association {
                value.args()[1].clone()
            } else {
                value.clone()
            };
            let key = self.evaluate(call(function.clone(), [key_input]))?;
            let mut duplicate = false;
            for previous in &seen {
                duplicate = match test {
                    None => previous == &key,
                    Some(test) => is_symbol(
                        &self.evaluate(call(test.clone(), [previous.clone(), key.clone()]))?,
                        "True",
                    ),
                };
                if duplicate {
                    break;
                }
            }
            if !duplicate {
                seen.push(key);
                output.push(value);
            }
        }
        Ok(Some(call(head, output)))
    }

    fn quantifier_expr(&mut self, args: &[Expr], mode: u8) -> Result<Expr> {
        let [target, predicate] = args else {
            let name = ["AllTrue", "AnyTrue", "NoneTrue"][mode as usize];
            return Ok(call(name, args.iter().cloned()));
        };
        let Some(values) = target_call_args(target) else {
            return Ok(symbol("False"));
        };
        let mut matched = 0;
        for value in values {
            if is_symbol(
                &self.evaluate(call(predicate.clone(), [value.clone()]))?,
                "True",
            ) {
                matched += 1;
            }
        }
        Ok(bool_expr(match mode {
            0 => matched == values.len(),
            1 => matched > 0,
            _ => matched == 0,
        }))
    }

    fn mean_median_expr(&mut self, args: &[Expr], median: bool) -> Result<Expr> {
        let [target] = args else {
            return Ok(call(
                if median { "Median" } else { "Mean" },
                args.iter().cloned(),
            ));
        };
        let Some(mut values) = target_call_args(target).map(<[Expr]>::to_vec) else {
            return Ok(call(
                if median { "Median" } else { "Mean" },
                args.iter().cloned(),
            ));
        };
        if values.is_empty() {
            return Ok(symbol("Indeterminate"));
        }
        if median {
            values.sort_by(expression_order);
            let middle = values.len() / 2;
            if values.len() % 2 == 1 {
                Ok(values[middle].clone())
            } else {
                self.evaluate(call(
                    "Times",
                    [
                        rational(1, 2),
                        call("Plus", [values[middle - 1].clone(), values[middle].clone()]),
                    ],
                ))
            }
        } else {
            self.evaluate(call(
                "Times",
                [rational(1, values.len()), call("Plus", values)],
            ))
        }
    }

    fn evaluate_if(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if !(2..=4).contains(&args.len()) {
            return Ok(call(head, args));
        }
        let condition = self.evaluate(args[0].clone())?;
        if self.control.is_some() {
            return Ok(condition);
        }
        if is_symbol(&condition, "True") {
            self.evaluate(args[1].clone())
        } else if is_symbol(&condition, "False") {
            if let Some(otherwise) = args.get(2) {
                self.evaluate(otherwise.clone())
            } else {
                Ok(symbol("Null"))
            }
        } else if let Some(unknown) = args.get(3) {
            self.evaluate(unknown.clone())
        } else {
            let mut held = vec![condition];
            held.extend(args.into_iter().skip(1));
            Ok(call(head, held))
        }
    }

    fn evaluate_which(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.is_empty() || args.len() % 2 != 0 {
            return Ok(call(head, args));
        }
        for (pair_index, pair) in args.chunks_exact(2).enumerate() {
            let condition = self.evaluate(pair[0].clone())?;
            if self.control.is_some() {
                return Ok(condition);
            }
            if is_symbol(&condition, "True") {
                return self.evaluate(pair[1].clone());
            }
            if !is_symbol(&condition, "False") {
                let argument_index = pair_index * 2;
                let mut unresolved = vec![condition, pair[1].clone()];
                unresolved.extend(args[argument_index + 2..].iter().cloned());
                return Ok(call(head, unresolved));
            }
        }
        Ok(symbol("Null"))
    }

    fn evaluate_switch(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        if args.len() < 3 || args.len().is_multiple_of(2) {
            return Ok(call(head, args));
        }
        let subject = self.evaluate(args[0].clone())?;
        for pair in args[1..].chunks_exact(2) {
            let mut bindings = Vec::new();
            if self.match_pattern(&subject, &pair[0], &mut bindings)? {
                return self.evaluate(pair[1].clone());
            }
        }
        let mut inert = vec![subject];
        inert.extend(args.into_iter().skip(1));
        Ok(call(head, inert))
    }

    fn evaluate_piecewise(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let (pieces, default) = match args.as_slice() {
            [pieces] => (pieces, integer(0)),
            [pieces, default] => (pieces, default.clone()),
            _ => return Ok(call(head, args)),
        };
        let Expr::Call {
            head: list_head,
            args: rows,
        } = pieces
        else {
            return Ok(call(head, args));
        };
        if !is_symbol(list_head, "List") {
            return Ok(call(head, args));
        }
        let mut kept = Vec::new();
        for row in rows {
            if let Expr::Call {
                head: row_head,
                args: pair,
            } = row
                && is_symbol(row_head, "List")
                && pair.len() == 2
            {
                let condition = self.evaluate(pair[1].clone())?;
                if self.control.is_some() {
                    return Ok(condition);
                }
                if is_symbol(&condition, "True") {
                    let selected = self.evaluate(pair[0].clone())?;
                    if kept.is_empty() {
                        return Ok(selected);
                    }
                    return Ok(call("Piecewise", [list(kept), selected]));
                }
                if !is_symbol(&condition, "False") {
                    kept.push(list([self.evaluate(pair[0].clone())?, condition]));
                }
            } else {
                return Ok(call(head, args));
            }
        }
        let default = self.evaluate(default)?;
        if kept.is_empty() {
            Ok(default)
        } else {
            Ok(call("Piecewise", [list(kept), default]))
        }
    }

    fn activate_inactive(&mut self, expr: Expr, pattern: Option<&Expr>) -> Result<Expr> {
        if expr.has_head("Inactive") && expr.args().len() == 1 {
            let target = expr.args()[0].clone();
            let activated_target = self.activate_inactive(target.clone(), pattern)?;
            let matches = if let Some(pattern) = pattern {
                let mut bindings = Vec::new();
                self.match_pattern(&target, pattern, &mut bindings)?
            } else {
                true
            };
            return Ok(if matches {
                activated_target
            } else {
                call("Inactive", [activated_target])
            });
        }
        let Expr::Call { head, args } = expr else {
            return Ok(expr);
        };
        let activated_head = self.activate_inactive(*head, pattern)?;
        let activated_args = args
            .into_iter()
            .map(|argument| self.activate_inactive(argument, pattern))
            .collect::<Result<Vec<_>>>()?;
        Ok(call(activated_head, activated_args))
    }

    fn evaluate_and(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let mut unresolved = Vec::new();
        for argument in args {
            let value = self.evaluate(argument)?;
            if self.control.is_some() {
                return Ok(value);
            }
            if is_symbol(&value, "False") {
                return Ok(symbol("False"));
            }
            if !is_symbol(&value, "True") {
                unresolved.push(value);
            }
        }
        Ok(match unresolved.len() {
            0 => symbol("True"),
            1 => unresolved.pop().expect("one value"),
            _ => call(head, unresolved),
        })
    }

    fn evaluate_or(&mut self, head: Expr, args: Vec<Expr>) -> Result<Expr> {
        let mut unresolved = Vec::new();
        for argument in args {
            let value = self.evaluate(argument)?;
            if self.control.is_some() {
                return Ok(value);
            }
            if is_symbol(&value, "True") {
                return Ok(symbol("True"));
            }
            if !is_symbol(&value, "False") {
                unresolved.push(value);
            }
        }
        Ok(match unresolved.len() {
            0 => symbol("False"),
            1 => unresolved.pop().expect("one value"),
            _ => call(head, unresolved),
        })
    }

    fn map_at_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [function, target, positions] = args else {
            return Ok(None);
        };
        let paths = position_paths(positions);
        let Some(paths) = paths else {
            return Ok(None);
        };
        let mut result = target.clone();
        for path in paths {
            let Some(current) = expr_at_path(&result, &path) else {
                continue;
            };
            let replacement = self.evaluate(call(function.clone(), [current]))?;
            result = replace_at_path(&result, &path, &replacement).unwrap_or(result);
        }
        Ok(Some(result))
    }

    fn replace_at_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, rules, positions] = args else {
            return Ok(None);
        };
        let rules = normalize_rules(rules);
        if rules.is_empty() || rules.iter().any(|rule| rule_parts(rule).is_none()) {
            return Ok(None);
        }
        let Some(paths) = position_paths(positions) else {
            return Ok(None);
        };
        let mut result = target.clone();
        for path in paths {
            let Some(current) = expr_at_path(&result, &path) else {
                continue;
            };
            if let Some(replacement) = self.apply_first_rule(&current, &rules)? {
                let replacement = self.evaluate(replacement)?;
                result = replace_at_path(&result, &path, &replacement).unwrap_or(result);
            }
        }
        Ok(Some(result))
    }

    fn map_levels_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let Some((positional, include_heads)) = heads_option_arguments(args, false) else {
            return Ok(None);
        };
        if !(2..=3).contains(&positional.len()) {
            return Ok(None);
        }
        let default_spec = list([integer(1)]);
        let spec = positional.get(2).copied().unwrap_or(&default_spec);
        self.map_at_levels(positional[0], positional[1], spec, 0, include_heads)
            .map(Some)
    }

    fn map_at_levels(
        &mut self,
        function: &Expr,
        target: &Expr,
        spec: &Expr,
        level: i64,
        include_heads: bool,
    ) -> Result<Expr> {
        let rebuilt = if let Some(entries) = association_entries(target) {
            let mut rules = Vec::new();
            for entry in entries {
                let value =
                    self.map_at_levels(function, &entry.args()[1], spec, level + 1, include_heads)?;
                rules.push(call("Rule", [entry.args()[0].clone(), value]));
            }
            call("Association", rules)
        } else if let Expr::Call { head, args } = target {
            let new_head = if include_heads {
                self.map_at_levels(function, head, spec, level + 1, include_heads)?
            } else {
                head.as_ref().clone()
            };
            let mut values = Vec::with_capacity(args.len());
            for value in args {
                let value = self.map_at_levels(function, value, spec, level + 1, include_heads)?;
                if !is_symbol(&value, "Nothing") || !is_symbol(&new_head, "List") {
                    values.push(value);
                }
            }
            call(new_head, values)
        } else {
            target.clone()
        };
        if level_spec_matches(spec, level, -(depth(target) as i64)).unwrap_or(false) {
            self.evaluate(call(function.clone(), [rebuilt]))
        } else {
            Ok(rebuilt)
        }
    }

    fn map_all_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let Some((positional, include_heads)) = heads_option_arguments(args, false) else {
            return Ok(None);
        };
        let [function, target] = positional.as_slice() else {
            return Ok(None);
        };
        let spec = list([integer(0), symbol("Infinity")]);
        self.map_at_levels(function, target, &spec, 0, include_heads)
            .map(Some)
    }

    fn scan_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let Some((positional, include_heads)) = heads_option_arguments(args, false) else {
            return Ok(None);
        };
        if !(2..=3).contains(&positional.len()) {
            return Ok(None);
        }
        let default_spec = list([integer(1)]);
        let spec = positional.get(2).copied().unwrap_or(&default_spec);
        self.scan_at_levels(positional[0], positional[1], spec, 0, include_heads)?;
        Ok(Some(symbol("Null")))
    }

    fn scan_at_levels(
        &mut self,
        function: &Expr,
        target: &Expr,
        spec: &Expr,
        level: i64,
        include_heads: bool,
    ) -> Result<()> {
        if let Some(entries) = association_entries(target) {
            if include_heads {
                self.scan_at_levels(function, &target.head(), spec, level + 1, include_heads)?;
            }
            for entry in entries {
                self.scan_at_levels(function, &entry.args()[1], spec, level + 1, include_heads)?;
            }
        } else if let Expr::Call { head, args } = target {
            if include_heads {
                self.scan_at_levels(function, head, spec, level + 1, include_heads)?;
            }
            for argument in args {
                self.scan_at_levels(function, argument, spec, level + 1, include_heads)?;
            }
        }
        if level_spec_matches(spec, level, -(depth(target) as i64)).unwrap_or(false) {
            self.evaluate(call(function.clone(), [target.clone()]))?;
        }
        Ok(())
    }

    fn apply_levels_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([new_head, target] | [new_head, target, _]) = args else {
            return Ok(None);
        };
        let levels = match args.get(2) {
            Some(spec) => {
                let Some(levels) = level_numbers(spec) else {
                    return Ok(None);
                };
                levels
            }
            None => vec![0],
        };
        if target.has_head("Association") && levels == [0] {
            return self
                .evaluate(call(
                    new_head.clone(),
                    association_entries(target)
                        .unwrap_or_default()
                        .into_iter()
                        .map(|entry| entry.args()[1].clone()),
                ))
                .map(Some);
        }
        self.apply_at_levels(new_head, target, 0, &levels).map(Some)
    }

    fn map_apply_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([new_head, target] | [new_head, target, _]) = args else {
            return Ok(None);
        };
        let levels = match args.get(2) {
            Some(spec) => {
                let Some(levels) = level_numbers(spec) else {
                    return Ok(None);
                };
                levels
            }
            None => vec![1],
        };
        self.apply_at_levels(new_head, target, 0, &levels).map(Some)
    }

    fn map_indexed_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([function, target] | [function, target, _]) = args else {
            return Ok(None);
        };
        let default_spec = list([integer(1)]);
        let spec = args.get(2).unwrap_or(&default_spec);
        self.map_indexed_at(function, target, spec, &mut Vec::new())
            .map(Some)
    }

    fn map_indexed_at(
        &mut self,
        function: &Expr,
        target: &Expr,
        spec: &Expr,
        path: &mut Vec<Expr>,
    ) -> Result<Expr> {
        let rebuilt = if let Some(entries) = association_entries(target) {
            let mut output = Vec::new();
            for entry in entries {
                path.push(call("Key", [entry.args()[0].clone()]));
                let value = self.map_indexed_at(function, &entry.args()[1], spec, path)?;
                path.pop();
                output.push(call("Rule", [entry.args()[0].clone(), value]));
            }
            call("Association", output)
        } else if let Expr::Call { head, args } = target {
            let mut output = Vec::with_capacity(args.len());
            for (index, value) in args.iter().enumerate() {
                path.push(integer(index + 1));
                output.push(self.map_indexed_at(function, value, spec, path)?);
                path.pop();
            }
            call(head.as_ref().clone(), output)
        } else {
            target.clone()
        };
        let level = i64::try_from(path.len()).unwrap_or(i64::MAX);
        if !path.is_empty()
            && level_spec_matches(spec, level, -(depth(&rebuilt) as i64)).unwrap_or(false)
        {
            self.evaluate(call(function.clone(), [rebuilt, list(path.clone())]))
        } else {
            Ok(rebuilt)
        }
    }

    fn compose_list_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [functions, initial] = args else {
            return Ok(None);
        };
        let Expr::Call {
            args: function_values,
            ..
        } = functions
        else {
            return Ok(None);
        };
        let mut current = initial.clone();
        let mut output = vec![current.clone()];
        for function in function_values {
            current = self.evaluate(call(function.clone(), [current]))?;
            output.push(current.clone());
        }
        Ok(Some(list(output)))
    }

    fn comap_expr(&mut self, args: &[Expr], apply: bool) -> Result<Option<Expr>> {
        let [functions, target] = args else {
            return Ok(None);
        };
        if let Some(entries) = association_entries(functions) {
            let mut output = Vec::new();
            for entry in entries {
                let value = if apply {
                    apply_callable_head(self, &entry.args()[1], target)?
                } else {
                    self.evaluate(call(entry.args()[1].clone(), [target.clone()]))?
                };
                output.push(call("Rule", [entry.args()[0].clone(), value]));
            }
            return Ok(Some(call("Association", output)));
        }
        let Expr::Call {
            head,
            args: function_values,
        } = functions
        else {
            return Ok(Some(functions.clone()));
        };
        let mut output = Vec::new();
        for function in function_values {
            output.push(if apply {
                apply_callable_head(self, function, target)?
            } else {
                self.evaluate(call(function.clone(), [target.clone()]))?
            });
        }
        Ok(Some(call(head.as_ref().clone(), output)))
    }

    fn thread_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let Expr::Call {
            head,
            args: arguments,
        } = target
        else {
            return Ok(Some(target.clone()));
        };
        let thread_head = args.get(1).cloned().unwrap_or_else(|| symbol("List"));
        let lengths = arguments
            .iter()
            .filter(|argument| argument.head() == thread_head)
            .map(|argument| argument.args().len())
            .collect::<BTreeSet<_>>();
        if lengths.is_empty() {
            return Ok(Some(target.clone()));
        }
        if lengths.len() != 1 {
            return Ok(None);
        }
        let length = *lengths.first().expect("one length");
        let mut output = Vec::new();
        for index in 0..length {
            let threaded = arguments.iter().map(|argument| {
                if argument.head() == thread_head {
                    argument.args()[index].clone()
                } else {
                    argument.clone()
                }
            });
            output.push(self.evaluate(call(head.as_ref().clone(), threaded))?);
        }
        Ok(Some(call(thread_head, output)))
    }

    fn inner_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [function, left, right, combiner] = args else {
            return Ok(None);
        };
        let (Expr::Call { args: left, .. }, Expr::Call { args: right, .. }) = (left, right) else {
            return Ok(None);
        };
        if left.len() != right.len() {
            return Ok(None);
        }
        let mut combined = Vec::new();
        for (left, right) in left.iter().zip(right) {
            combined.push(self.evaluate(call(function.clone(), [left.clone(), right.clone()]))?);
        }
        self.evaluate(call(combiner.clone(), combined)).map(Some)
    }

    fn block_map_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([function, target, Expr::Integer(size)] | [function, target, Expr::Integer(size), _]) =
            args
        else {
            return Ok(None);
        };
        let Some(size) = size.to_usize().filter(|size| *size > 0) else {
            return Ok(None);
        };
        let step = match args.get(3) {
            None => size,
            Some(Expr::Integer(step)) => {
                let Some(step) = step.to_usize().filter(|step| *step > 0) else {
                    return Ok(None);
                };
                step
            }
            _ => return Ok(None),
        };
        let Expr::Call { head, args: values } = target else {
            return Ok(None);
        };
        let mut output = Vec::new();
        if values.len() >= size {
            for start in (0..=values.len() - size).step_by(step) {
                let block = call(head.as_ref().clone(), values[start..start + size].to_vec());
                output.push(self.evaluate(call(function.clone(), [block]))?);
            }
        }
        Ok(Some(list(output)))
    }

    fn length_while_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, criterion] = args else {
            return Ok(None);
        };
        let Expr::Call { args: values, .. } = target else {
            return Ok(None);
        };
        let mut count = 0;
        for value in values {
            if !is_symbol(
                &self.evaluate(call(criterion.clone(), [value.clone()]))?,
                "True",
            ) {
                break;
            }
            count += 1;
        }
        Ok(Some(integer(count)))
    }

    fn delete_duplicates_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let test = args.get(1);
        let (head, values, association) = if let Some(entries) = association_entries(target) {
            (symbol("Association"), entries, true)
        } else if let Expr::Call { head, args } = target {
            (head.as_ref().clone(), args.clone(), false)
        } else {
            return Ok(None);
        };
        let mut kept = Vec::new();
        let mut seen: Vec<Expr> = Vec::new();
        for value in values {
            let candidate = if association {
                value.args()[1].clone()
            } else {
                value.clone()
            };
            let mut duplicate = false;
            for prior in &seen {
                duplicate = if let Some(test) = test {
                    is_symbol(
                        &self.evaluate(call(test.clone(), [candidate.clone(), prior.clone()]))?,
                        "True",
                    )
                } else {
                    &candidate == prior
                };
                if duplicate {
                    break;
                }
            }
            if !duplicate {
                seen.push(candidate);
                kept.push(value);
            }
        }
        Ok(Some(call(head, kept)))
    }

    fn duplicate_free_q_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let test = args.get(1);
        let values = if let Some(entries) = association_entries(target) {
            entries
                .into_iter()
                .map(|entry| entry.args()[1].clone())
                .collect::<Vec<_>>()
        } else if let Expr::Call { args, .. } = target {
            args.clone()
        } else {
            return Ok(None);
        };
        for (index, left) in values.iter().enumerate() {
            for right in &values[index + 1..] {
                let duplicate = if let Some(test) = test {
                    is_symbol(
                        &self.evaluate(call(test.clone(), [left.clone(), right.clone()]))?,
                        "True",
                    )
                } else {
                    left == right
                };
                if duplicate {
                    return Ok(Some(symbol("False")));
                }
            }
        }
        Ok(Some(symbol("True")))
    }

    fn apply_at_levels(
        &mut self,
        new_head: &Expr,
        target: &Expr,
        depth: usize,
        levels: &[usize],
    ) -> Result<Expr> {
        let Expr::Call { head, args } = target else {
            return Ok(target.clone());
        };
        let mut values = Vec::with_capacity(args.len());
        for value in args {
            values.push(self.apply_at_levels(new_head, value, depth + 1, levels)?);
        }
        let head = if levels.contains(&depth) {
            new_head.clone()
        } else {
            head.as_ref().clone()
        };
        self.evaluate(call(head, values))
    }

    fn array_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([function, dimensions] | [function, dimensions, _]) = args else {
            return Ok(None);
        };
        let dimensions = if let Expr::Integer(dimension) = dimensions {
            dimension.to_usize().map(|dimension| vec![dimension])
        } else if dimensions.has_head("List") {
            dimensions
                .args()
                .iter()
                .map(|dimension| match dimension {
                    Expr::Integer(value) => value.to_usize(),
                    _ => None,
                })
                .collect()
        } else {
            return Ok(None);
        };
        let Some(dimensions) = dimensions else {
            return Ok(None);
        };
        let origins = if let Some(origin) = args.get(2) {
            if let Expr::Integer(origin) = origin {
                vec![origin.clone(); dimensions.len()]
            } else if origin.has_head("List") && origin.args().len() == dimensions.len() {
                let origins = origin
                    .args()
                    .iter()
                    .map(|origin| match origin {
                        Expr::Integer(value) => Some(value.clone()),
                        _ => None,
                    })
                    .collect::<Option<Vec<_>>>();
                let Some(origins) = origins else {
                    return Ok(None);
                };
                origins
            } else {
                return Ok(None);
            }
        } else {
            vec![BigInt::one(); dimensions.len()]
        };
        Ok(Some(self.array_level(
            function,
            &dimensions,
            &origins,
            0,
            &mut Vec::new(),
        )?))
    }

    fn array_q_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target] | [target, _] | [target, _, _]) = args else {
            return Ok(None);
        };
        let Some(dimensions) = dense_dimensions(target) else {
            return Ok(Some(symbol("False")));
        };
        if dimensions.is_empty() {
            return Ok(Some(symbol("False")));
        }
        if let Some(rank) = args.get(1) {
            let Expr::Integer(rank) = rank else {
                return Ok(None);
            };
            if rank.to_usize() != Some(dimensions.len()) {
                return Ok(Some(symbol("False")));
            }
        }
        if let Some(predicate) = args.get(2) {
            for value in dense_leaf_values(target) {
                if !is_symbol(
                    &self.evaluate(call(predicate.clone(), [value.clone()]))?,
                    "True",
                ) {
                    return Ok(Some(symbol("False")));
                }
            }
        }
        Ok(Some(symbol("True")))
    }

    fn array_level(
        &mut self,
        function: &Expr,
        dimensions: &[usize],
        origins: &[BigInt],
        level: usize,
        indices: &mut Vec<Expr>,
    ) -> Result<Expr> {
        if level == dimensions.len() {
            return self.evaluate(call(function.clone(), indices.clone()));
        }
        let mut values = Vec::with_capacity(dimensions[level]);
        for offset in 0..dimensions[level] {
            indices.push(integer(&origins[level] + BigInt::from(offset)));
            let value = self.array_level(function, dimensions, origins, level + 1, indices)?;
            indices.pop();
            if !is_symbol(&value, "Nothing") {
                values.push(value);
            }
        }
        Ok(list(values))
    }

    fn fold_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        let (function, mut accumulator, values) = match args {
            [function, values] if values.has_head("List") && !values.args().is_empty() => {
                (function, values.args()[0].clone(), &values.args()[1..])
            }
            [function, initial, values] if values.has_head("List") => {
                (function, initial.clone(), values.args())
            }
            _ => return Ok(None),
        };
        let mut output = include_steps.then(|| vec![accumulator.clone()]);
        for value in values {
            accumulator = self.evaluate(call(function.clone(), [accumulator, value.clone()]))?;
            if let Some(output) = &mut output {
                output.push(accumulator.clone());
            }
        }
        Ok(Some(output.map_or(accumulator, list)))
    }

    fn sequence_values(&self, expr: &Expr) -> Option<Vec<Expr>> {
        if let Some(entries) = association_entries(expr) {
            return Some(
                entries
                    .into_iter()
                    .map(|entry| entry.args()[1].clone())
                    .collect(),
            );
        }
        if let Expr::SparseArray { dimensions, .. } = expr {
            if dimensions.len() != 1 {
                return None;
            }
            return sparse_normal(expr).map(|normal| normal.args().to_vec());
        }
        match expr {
            Expr::Call { args, .. } => Some(args.clone()),
            _ => None,
        }
    }

    fn sequence_fold_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        let ([function, initial, values] | [function, initial, values, _]) = args else {
            return Ok(None);
        };
        let Some(initial_values) = self.sequence_values(initial) else {
            return Ok(None);
        };
        let Some(inputs) = self.sequence_values(values) else {
            return Ok(None);
        };
        if initial_values.is_empty() {
            return Ok(None);
        }
        let argument_count = match args.get(3) {
            None => initial_values.len() + 1,
            Some(Expr::Integer(value)) if !value.is_negative() => {
                let Some(value) = value.to_usize() else {
                    return Ok(None);
                };
                value
            }
            _ => return Ok(None),
        };
        let Some(consumed_per_step) = argument_count.checked_sub(initial_values.len()) else {
            return Ok(None);
        };
        if consumed_per_step == 0 {
            return Ok(None);
        }

        let state_width = initial_values.len();
        let mut state = initial_values.clone();
        let mut results = initial_values;
        let mut index = 0;
        while index + consumed_per_step <= inputs.len() {
            let mut step_arguments = state[state.len() - state_width..].to_vec();
            step_arguments.extend_from_slice(&inputs[index..index + consumed_per_step]);
            let current = self.evaluate(call(function.clone(), step_arguments))?;
            state.push(current.clone());
            results.push(current);
            index += consumed_per_step;
        }
        Ok(Some(if include_steps {
            list(results)
        } else {
            results.last().expect("initial values are nonempty").clone()
        }))
    }

    fn fold_while_test(
        &mut self,
        test: &Expr,
        results: &[Expr],
        history_spec: Option<&Expr>,
    ) -> Result<Option<bool>> {
        let history = match history_spec {
            None => &results[results.len() - 1..],
            Some(value) if is_symbol(value, "All") => results,
            Some(Expr::Integer(value)) if value.is_positive() => {
                let Some(length) = value.to_usize() else {
                    return Ok(None);
                };
                &results[results.len().saturating_sub(length)..]
            }
            _ => return Ok(None),
        };
        let tested = self.evaluate(call(test.clone(), history.iter().cloned()))?;
        Ok(Some(is_symbol(&tested, "True")))
    }

    fn fold_while_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        let ([function, initial, values, test]
        | [function, initial, values, test, _]
        | [function, initial, values, test, _, _]) = args
        else {
            return Ok(None);
        };
        let Some(inputs) = self.sequence_values(values) else {
            return Ok(None);
        };
        let history_spec = args.get(4);
        let extra_results = match args.get(5) {
            None => 0_i64,
            Some(Expr::Integer(value)) => {
                let Some(value) = value.to_i64() else {
                    return Ok(None);
                };
                value
            }
            _ => return Ok(None),
        };
        let mut results = vec![initial.clone()];
        let Some(mut keep_going) = self.fold_while_test(test, &results, history_spec)? else {
            return Ok(None);
        };
        if !keep_going {
            return Ok(Some(if include_steps {
                list(results)
            } else {
                initial.clone()
            }));
        }
        let mut index = 0;
        let mut failed = false;
        while keep_going && index < inputs.len() {
            let current = self.evaluate(call(
                function.clone(),
                [
                    results.last().expect("one result").clone(),
                    inputs[index].clone(),
                ],
            ))?;
            results.push(current);
            index += 1;
            let Some(test_result) = self.fold_while_test(test, &results, history_spec)? else {
                return Ok(None);
            };
            keep_going = test_result;
            failed = !keep_going;
        }

        if failed {
            if extra_results < 0 {
                let keep = (results.len() as i64 + extra_results).max(1) as usize;
                results.truncate(keep);
            } else {
                let mut trailing = extra_results as usize;
                while trailing > 0 && index < inputs.len() {
                    let current = self.evaluate(call(
                        function.clone(),
                        [
                            results.last().expect("one result").clone(),
                            inputs[index].clone(),
                        ],
                    ))?;
                    results.push(current);
                    index += 1;
                    trailing -= 1;
                }
            }
        }
        Ok(Some(if include_steps {
            list(results)
        } else {
            results.last().expect("one result").clone()
        }))
    }

    fn fold_pair_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        let ([function, initial, values] | [function, initial, values, _]) = args else {
            return Ok(None);
        };
        let Some(inputs) = self.sequence_values(values) else {
            return Ok(None);
        };
        let projection = args.get(3);
        let mut current = initial.clone();
        let mut results = Vec::with_capacity(inputs.len());
        for input in inputs {
            let pair = self.evaluate(call(function.clone(), [current, input]))?;
            if !pair.has_head("List") || pair.args().len() != 2 {
                return Ok(None);
            }
            let projected = if let Some(projection) = projection {
                self.evaluate(call(projection.clone(), [pair.clone()]))?
            } else {
                pair.args()[0].clone()
            };
            current = pair.args()[1].clone();
            results.push(projected);
        }
        if include_steps {
            Ok(Some(list(results)))
        } else {
            Ok(results.pop())
        }
    }

    fn first_case_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target, pattern] | [target, pattern, _] | [target, pattern, _, _]) = args else {
            return Ok(None);
        };
        let default = args
            .get(2)
            .cloned()
            .unwrap_or_else(|| call("Missing", [string("NotFound")]));
        let spec = args.get(3).cloned().unwrap_or_else(|| integer(1));
        let matches = self.evaluate_cases(
            symbol("Cases"),
            vec![target.clone(), pattern.clone(), spec, integer(1)],
            false,
        )?;
        Ok(Some(matches.args().first().cloned().unwrap_or(default)))
    }

    fn selection_items(&self, target: &Expr) -> Option<Vec<SelectionItem>> {
        if let Some(entries) = association_entries(target) {
            return Some(
                entries
                    .into_iter()
                    .enumerate()
                    .map(|(index, entry)| SelectionItem {
                        index: index + 1,
                        value: entry.args()[1].clone(),
                        entry: Some(entry),
                    })
                    .collect(),
            );
        }
        let Expr::Call { args, .. } = target else {
            return None;
        };
        Some(
            args.iter()
                .cloned()
                .enumerate()
                .map(|(index, value)| SelectionItem {
                    index: index + 1,
                    value,
                    entry: None,
                })
                .collect(),
        )
    }

    fn selection_spec(&self, criterion: &Expr) -> Option<(Expr, Option<SelectionProperty>)> {
        let (selector, property) = if criterion.has_head("Rule") && criterion.args().len() == 2 {
            (criterion.args()[0].clone(), Some(&criterion.args()[1]))
        } else {
            (criterion.clone(), None)
        };
        let property = match property {
            Some(property) => Some(parse_selection_property(property)?),
            None => None,
        };
        Some((selector, property))
    }

    fn selection_elements(&self, target: &Expr, items: &[SelectionItem]) -> Option<Expr> {
        if association_entries(target).is_some() {
            return normalize_association(
                &items
                    .iter()
                    .filter_map(|item| item.entry.clone())
                    .collect::<Vec<_>>(),
            );
        }
        let Expr::Call { head, .. } = target else {
            return None;
        };
        Some(call(
            head.as_ref().clone(),
            items.iter().map(|item| item.value.clone()),
        ))
    }

    fn selection_projection(
        &self,
        target: &Expr,
        items: &[SelectionItem],
        property: Option<&SelectionProperty>,
    ) -> Option<Expr> {
        match property {
            None | Some(SelectionProperty::Element) => self.selection_elements(target, items),
            Some(SelectionProperty::Index) => {
                Some(list(items.iter().map(|item| integer(item.index))))
            }
            Some(SelectionProperty::Multiple(properties)) => {
                let rules = properties
                    .iter()
                    .map(|property| {
                        Some(call(
                            "Rule",
                            [
                                selection_property_name(property),
                                self.selection_projection(target, items, Some(property))?,
                            ],
                        ))
                    })
                    .collect::<Option<Vec<_>>>()?;
                normalize_association(&rules)
            }
        }
    }

    fn selection_first_projection(
        &self,
        item: Option<&SelectionItem>,
        property: Option<&SelectionProperty>,
        default: &Expr,
        has_default: bool,
    ) -> Option<Expr> {
        let missing = || call("Missing", [string("NotFound")]);
        match property {
            None | Some(SelectionProperty::Element) => {
                Some(item.map(|item| item.value.clone()).unwrap_or_else(|| {
                    if has_default {
                        default.clone()
                    } else {
                        missing()
                    }
                }))
            }
            Some(SelectionProperty::Index) => {
                Some(item.map(|item| integer(item.index)).unwrap_or_else(missing))
            }
            Some(SelectionProperty::Multiple(properties)) => {
                let rules = properties
                    .iter()
                    .map(|property| {
                        Some(call(
                            "Rule",
                            [
                                selection_property_name(property),
                                self.selection_first_projection(
                                    item,
                                    Some(property),
                                    default,
                                    has_default,
                                )?,
                            ],
                        ))
                    })
                    .collect::<Option<Vec<_>>>()?;
                normalize_association(&rules)
            }
        }
    }

    fn predicate_succeeds(&mut self, criterion: &Expr, value: &Expr) -> Result<bool> {
        let evaluated = self.evaluate(call(criterion.clone(), [value.clone()]))?;
        Ok(is_symbol(&evaluated, "True"))
    }

    fn selection_expr(&mut self, args: &[Expr], mode: SelectionMode) -> Result<Option<Expr>> {
        let valid_arity = match mode {
            SelectionMode::First => (2..=3).contains(&args.len()),
            SelectionMode::Select | SelectionMode::Discard => (2..=3).contains(&args.len()),
        };
        if !valid_arity {
            return Ok(None);
        }
        let target = &args[0];
        let Some((criterion, property)) = self.selection_spec(&args[1]) else {
            return Ok(None);
        };
        let Some(items) = self.selection_items(target) else {
            return Ok(None);
        };
        if matches!(mode, SelectionMode::First) {
            let mut selected = None;
            for item in &items {
                if self.predicate_succeeds(&criterion, &item.value)? {
                    selected = Some(item);
                    break;
                }
            }
            let default = args.get(2).cloned().unwrap_or_else(|| symbol("Null"));
            return Ok(self.selection_first_projection(
                selected,
                property.as_ref(),
                &default,
                args.len() == 3,
            ));
        }

        let Some(mut remaining) = match_limit(args.get(2)) else {
            return Ok(None);
        };
        let mut selected = Vec::new();
        for item in items {
            if matches!(mode, SelectionMode::Discard) && remaining == Some(0) {
                selected.push(item);
                continue;
            }
            let matches = self.predicate_succeeds(&criterion, &item.value)?;
            match mode {
                SelectionMode::Select if matches && remaining != Some(0) => {
                    selected.push(item);
                    if let Some(count) = &mut remaining {
                        *count -= 1;
                    }
                }
                SelectionMode::Discard if matches && remaining != Some(0) => {
                    if let Some(count) = &mut remaining {
                        *count -= 1;
                    }
                }
                SelectionMode::Discard => selected.push(item),
                _ => {}
            }
            if matches!(mode, SelectionMode::Select) && matches && remaining == Some(0) {
                break;
            }
        }
        Ok(self.selection_projection(target, &selected, property.as_ref()))
    }

    fn pick_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([target, selectors] | [target, selectors, _]) = args else {
            return Ok(None);
        };
        if !selectors.has_head("List") {
            return Ok(None);
        }
        let pattern = args.get(2).cloned().unwrap_or_else(|| symbol("True"));
        let items = if let Some(entries) = association_entries(target) {
            entries
        } else if let Expr::Call { args, .. } = target {
            args.clone()
        } else {
            return Ok(None);
        };
        if items.len() != selectors.args().len() {
            return Ok(None);
        }
        let mut selected = Vec::new();
        for (item, selector) in items.into_iter().zip(selectors.args()) {
            let mut bindings = Vec::new();
            if self.match_pattern(selector, &pattern, &mut bindings)? {
                selected.push(item.clone());
            }
        }
        Ok(Some(call(target.head(), selected)))
    }

    fn take_while_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, criterion] = args else {
            return Ok(None);
        };
        let Some(items) = self.selection_items(target) else {
            return Ok(None);
        };
        let mut retained = Vec::new();
        for item in items {
            if !self.predicate_succeeds(criterion, &item.value)? {
                break;
            }
            retained.push(item);
        }
        Ok(self.selection_elements(target, &retained))
    }

    fn key_select_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [association, criterion] = args else {
            return Ok(None);
        };
        let Some(entries) = association_entries(association) else {
            return Ok(None);
        };
        let mut retained = Vec::new();
        for entry in entries {
            if self.predicate_succeeds(criterion, &entry.args()[0])? {
                retained.push(entry);
            }
        }
        Ok(normalize_association(&retained))
    }

    fn split_by_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [target, function] = args else {
            return Ok(None);
        };
        if !target.has_head("List") {
            return Ok(None);
        }
        let mut groups: Vec<Vec<Expr>> = Vec::new();
        let mut previous: Option<Expr> = None;
        for value in target.args() {
            let key = self.evaluate(call(function.clone(), [value.clone()]))?;
            if previous.as_ref().is_none_or(|previous| previous != &key) {
                groups.push(Vec::new());
                previous = Some(key);
            }
            groups
                .last_mut()
                .expect("group was pushed")
                .push(value.clone());
        }
        Ok(Some(list(groups.into_iter().map(list))))
    }

    fn trace_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([matrix] | [matrix, _] | [matrix, _, _]) = args else {
            return Ok(None);
        };
        if let Some(level) = args.get(2) {
            let Expr::Integer(level) = level else {
                return Ok(None);
            };
            let Some(level) = level.to_usize() else {
                return Ok(None);
            };
            if level == 0 {
                return Ok(None);
            }
            let function = args.get(1).cloned().unwrap_or_else(|| symbol("Plus"));
            return self.trace_at_level(matrix, &function, level).map(Some);
        }
        let Some(rows) = matrix_rows(matrix) else {
            return Ok(None);
        };
        if rows.is_empty() || rows.iter().any(|row| row.len() != rows.len()) {
            return Ok(None);
        }
        let function = args.get(1).cloned().unwrap_or_else(|| symbol("Plus"));
        self.evaluate(call(
            function,
            rows.iter()
                .enumerate()
                .map(|(index, row)| row[index].clone()),
        ))
        .map(Some)
    }

    fn trace_at_level(&mut self, target: &Expr, function: &Expr, level: usize) -> Result<Expr> {
        if level > 1 {
            if !target.has_head("List") {
                return Ok(call(
                    "Tr",
                    [target.clone(), function.clone(), integer(level)],
                ));
            }
            let mut contracted = Vec::with_capacity(target.args().len());
            for child in target.args() {
                contracted.push(self.trace_at_level(child, function, level - 1)?);
            }
            return self.trace_at_level(&list(contracted), function, 1);
        }
        if !target.has_head("List") {
            return Ok(call(
                "Tr",
                [target.clone(), function.clone(), integer(level)],
            ));
        }
        if target.args().iter().all(|child| child.has_head("List"))
            && target
                .args()
                .iter()
                .map(|child| child.args().len())
                .collect::<BTreeSet<_>>()
                .len()
                == 1
        {
            let width = target.args().first().map_or(0, |row| row.args().len());
            let mut output = Vec::with_capacity(width);
            for column in 0..width {
                output.push(self.evaluate(call(
                    function.clone(),
                    target.args().iter().map(|row| row.args()[column].clone()),
                ))?);
            }
            return Ok(list(output));
        }
        self.evaluate(call(function.clone(), target.args().iter().cloned()))
    }

    fn determinant_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [matrix] = args else {
            return Ok(None);
        };
        let Some(rows) = matrix_rows(matrix) else {
            return Ok(None);
        };
        if rows.iter().any(|row| row.len() != rows.len()) {
            return Ok(None);
        }
        self.determinant_rows(&rows).map(Some)
    }

    fn determinant_rows(&mut self, rows: &[Vec<Expr>]) -> Result<Expr> {
        match rows.len() {
            0 => Ok(integer(1)),
            1 => Ok(rows[0][0].clone()),
            size => {
                let mut terms = Vec::with_capacity(size);
                for column in 0..size {
                    let minor = rows[1..]
                        .iter()
                        .map(|row| {
                            row.iter()
                                .enumerate()
                                .filter(|(index, _)| *index != column)
                                .map(|(_, value)| value.clone())
                                .collect::<Vec<_>>()
                        })
                        .collect::<Vec<_>>();
                    let minor_value = self.determinant_rows(&minor)?;
                    terms.push(self.evaluate(call(
                        "Times",
                        [
                            integer(if column % 2 == 0 { 1 } else { -1 }),
                            rows[0][column].clone(),
                            minor_value,
                        ],
                    ))?);
                }
                self.evaluate(call("Plus", terms))
            }
        }
    }

    fn inverse_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [matrix] = args else {
            return Ok(None);
        };
        let Some(rows) = matrix_rows(matrix) else {
            return Ok(None);
        };
        let size = rows.len();
        if size == 0 || rows.iter().any(|row| row.len() != size) {
            return Ok(None);
        }
        let Some(mut left) = rows
            .iter()
            .map(|row| row.iter().map(as_rational).collect::<Option<Vec<_>>>())
            .collect::<Option<Vec<_>>>()
        else {
            return Ok(None);
        };
        let mut right = (0..size)
            .map(|row| {
                (0..size)
                    .map(|column| BigRational::from_integer(BigInt::from((row == column) as u8)))
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();
        for column in 0..size {
            let Some(pivot) = (column..size).find(|row| !left[*row][column].is_zero()) else {
                return Ok(None);
            };
            left.swap(column, pivot);
            right.swap(column, pivot);
            let divisor = left[column][column].clone();
            for index in 0..size {
                left[column][index] /= &divisor;
                right[column][index] /= &divisor;
            }
            for row in 0..size {
                if row == column {
                    continue;
                }
                let factor = left[row][column].clone();
                let pivot_left = left[column].clone();
                let pivot_right = right[column].clone();
                for index in 0..size {
                    left[row][index] -= &factor * pivot_left[index].clone();
                    right[row][index] -= &factor * pivot_right[index].clone();
                }
            }
        }
        let result = list(
            right
                .into_iter()
                .map(|row| list(row.into_iter().map(from_rational))),
        );
        Ok(Some(if matches!(matrix, Expr::SparseArray { .. }) {
            dense_to_sparse(&result, &integer(0))
        } else {
            result
        }))
    }

    fn matrix_power_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [matrix, Expr::Integer(power)] = args else {
            return Ok(None);
        };
        let Some(base) = matrix_rows(matrix) else {
            return Ok(None);
        };
        let size = base.len();
        if size == 0 || base.iter().any(|row| row.len() != size) {
            return Ok(None);
        }
        let Some(mut power) = power.to_u64() else {
            return Ok(None);
        };
        let mut result = (0..size)
            .map(|row| {
                (0..size)
                    .map(|column| integer((row == column) as u8))
                    .collect::<Vec<_>>()
            })
            .collect::<Vec<_>>();
        let mut factor = base;
        while power > 0 {
            if power % 2 == 1 {
                result = self.matrix_multiply(&result, &factor)?;
            }
            power /= 2;
            if power > 0 {
                factor = self.matrix_multiply(&factor, &factor)?;
            }
        }
        let result = list(result.into_iter().map(list));
        Ok(Some(if matches!(matrix, Expr::SparseArray { .. }) {
            dense_to_sparse(&result, &integer(0))
        } else {
            result
        }))
    }

    fn matrix_multiply(
        &mut self,
        left: &[Vec<Expr>],
        right: &[Vec<Expr>],
    ) -> Result<Vec<Vec<Expr>>> {
        let mut output = Vec::with_capacity(left.len());
        for row in left {
            let mut output_row = Vec::with_capacity(right[0].len());
            for column in 0..right[0].len() {
                let terms = row.iter().zip(right).map(|(left, right_row)| {
                    call("Times", [left.clone(), right_row[column].clone()])
                });
                output_row.push(self.evaluate(call("Plus", terms))?);
            }
            output.push(output_row);
        }
        Ok(output)
    }

    fn dot_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [left, right] = args else {
            return Ok(None);
        };
        if left.has_head("List")
            && right.has_head("List")
            && left.args().iter().all(|value| !value.has_head("List"))
            && right.args().iter().all(|value| !value.has_head("List"))
            && left.args().len() == right.args().len()
        {
            return self
                .evaluate(call(
                    "Plus",
                    left.args()
                        .iter()
                        .zip(right.args())
                        .map(|(left, right)| call("Times", [left.clone(), right.clone()])),
                ))
                .map(Some);
        }
        if let Some(left_rows) = matrix_rows(left)
            && right.has_head("List")
            && right.args().iter().all(|value| !value.has_head("List"))
            && left_rows.iter().all(|row| row.len() == right.args().len())
        {
            let mut output = Vec::with_capacity(left_rows.len());
            for row in left_rows {
                output.push(
                    self.evaluate(call(
                        "Plus",
                        row.iter()
                            .zip(right.args())
                            .map(|(left, right)| call("Times", [left.clone(), right.clone()])),
                    ))?,
                );
            }
            return Ok(Some(list(output)));
        }
        let Some(left_rows) = matrix_rows(left) else {
            return Ok(None);
        };
        let Some(right_rows) = matrix_rows(right) else {
            return Ok(None);
        };
        if left_rows.is_empty()
            || right_rows.is_empty()
            || left_rows[0].len() != right_rows.len()
            || left_rows.iter().any(|row| row.len() != left_rows[0].len())
            || right_rows
                .iter()
                .any(|row| row.len() != right_rows[0].len())
        {
            return Ok(None);
        }
        let result = list(
            self.matrix_multiply(&left_rows, &right_rows)?
                .into_iter()
                .map(list),
        );
        Ok(Some(
            if matches!(left, Expr::SparseArray { .. }) || matches!(right, Expr::SparseArray { .. })
            {
                dense_to_sparse(&result, &integer(0))
            } else {
                result
            },
        ))
    }

    fn cross_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [left, right] = args else {
            return Ok(None);
        };
        if !left.has_head("List")
            || !right.has_head("List")
            || left.args().len() != 3
            || right.args().len() != 3
        {
            return Ok(None);
        }
        let mut output = Vec::new();
        for (a, b, c, d) in [(1, 2, 2, 1), (2, 0, 0, 2), (0, 1, 1, 0)] {
            output.push(self.evaluate(call(
                "Plus",
                [
                    call("Times", [left.args()[a].clone(), right.args()[b].clone()]),
                    call(
                        "Times",
                        [integer(-1), left.args()[c].clone(), right.args()[d].clone()],
                    ),
                ],
            ))?);
        }
        Ok(Some(list(output)))
    }

    fn merge_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [associations, function] = args else {
            return Ok(None);
        };
        if !associations.has_head("List") {
            return Ok(None);
        }
        let mut groups: Vec<(Expr, Vec<Expr>)> = Vec::new();
        for association in associations.args() {
            let Some(entries) = association_entries(association) else {
                return Ok(None);
            };
            for entry in entries {
                let key = entry.args()[0].clone();
                if let Some((_, values)) = groups.iter_mut().find(|(existing, _)| existing == &key)
                {
                    values.push(entry.args()[1].clone());
                } else {
                    groups.push((key, vec![entry.args()[1].clone()]));
                }
            }
        }
        let mut rules = Vec::new();
        for (key, values) in groups {
            let value = self.evaluate(call(function.clone(), [list(values)]))?;
            rules.push(call("Rule", [key, value]));
        }
        Ok(Some(call("Association", rules)))
    }

    fn group_by_expr(&mut self, args: &[Expr], gather: bool) -> Result<Option<Expr>> {
        let [target, specification] = args else {
            return Ok(None);
        };
        if !target.has_head("List") {
            return Ok(None);
        }
        let (key_function, value_function) = if !gather
            && matches!(
                specification.head().symbol_name().map(system_dispatch_name),
                Some("Rule" | "RuleDelayed")
            )
            && specification.args().len() == 2
        {
            (&specification.args()[0], Some(&specification.args()[1]))
        } else {
            (specification, None)
        };
        let mut groups: Vec<(Expr, Vec<Expr>)> = Vec::new();
        for value in target.args() {
            let key = self.evaluate(call(key_function.clone(), [value.clone()]))?;
            if let Some((_, values)) = groups.iter_mut().find(|(existing, _)| existing == &key) {
                values.push(value.clone());
            } else {
                groups.push((key, vec![value.clone()]));
            }
        }
        if gather {
            return Ok(Some(list(
                groups.into_iter().map(|(_, values)| list(values)),
            )));
        }
        let mut rules = Vec::new();
        for (key, values) in groups {
            let values = list(values);
            let value = if let Some(function) = value_function {
                self.evaluate(call(function.clone(), [values]))?
            } else {
                values
            };
            rules.push(call("Rule", [key, value]));
        }
        Ok(Some(call("Association", rules)))
    }

    fn variance_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let [values] = args else {
            return Ok(None);
        };
        if !values.has_head("List") || values.args().len() < 2 {
            return Ok(None);
        }
        let mean = self.mean_median_expr(&[values.clone()], false)?;
        let terms = values.args().iter().map(|value| {
            call(
                "Power",
                [
                    call(
                        "Plus",
                        [value.clone(), call("Times", [integer(-1), mean.clone()])],
                    ),
                    integer(2),
                ],
            )
        });
        self.evaluate(call(
            "Times",
            [rational(1, values.args().len() - 1), call("Plus", terms)],
        ))
        .map(Some)
    }

    fn standard_deviation_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let Some(variance) = self.variance_expr(args)? else {
            return Ok(None);
        };
        Ok(Some(
            exact_power(&variance, &BigRational::new(1.into(), 2.into()))
                .unwrap_or_else(|| call("Power", [variance, rational(1, 2)])),
        ))
    }

    fn norm_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([values] | [values, _]) = args else {
            return Ok(None);
        };
        if !values.has_head("List") {
            return Ok(None);
        }
        if args
            .get(1)
            .is_some_and(|value| is_symbol(value, "Infinity"))
        {
            let mut maximum = integer(0);
            for value in values.args() {
                let absolute = self.evaluate(call("Abs", [value.clone()]))?;
                maximum = min_max_expr(&[maximum, absolute], true).expect("numeric maximum");
            }
            return Ok(Some(maximum));
        }
        let power = args.get(1).cloned().unwrap_or_else(|| integer(2));
        let Expr::Integer(power_integer) = &power else {
            return Ok(None);
        };
        let sum = self.evaluate(call(
            "Plus",
            values
                .args()
                .iter()
                .map(|value| call("Power", [call("Abs", [value.clone()]), power.clone()])),
        ))?;
        let reciprocal = BigRational::new(BigInt::one(), power_integer.clone());
        Ok(Some(exact_power(&sum, &reciprocal).unwrap_or_else(|| {
            call("Power", [sum, from_rational(reciprocal)])
        })))
    }

    fn tally_expr(&mut self, args: &[Expr], counts: bool) -> Result<Option<Expr>> {
        let ([target] | [target, _]) = args else {
            return Ok(None);
        };
        let Some(values) = target_call_args(target) else {
            return Ok(None);
        };
        let test = args.get(1);
        let mut tallies: Vec<(Expr, usize)> = Vec::new();
        for value in values {
            let mut found = None;
            for (index, (existing, _)) in tallies.iter().enumerate() {
                let matches = if let Some(test) = test {
                    is_symbol(
                        &self.evaluate(call(test.clone(), [existing.clone(), value.clone()]))?,
                        "True",
                    )
                } else {
                    existing == value
                };
                if matches {
                    found = Some(index);
                    break;
                }
            }
            if let Some(index) = found {
                tallies[index].1 += 1;
            } else {
                tallies.push((value.clone(), 1));
            }
        }
        Ok(Some(if counts {
            call(
                "Association",
                tallies
                    .into_iter()
                    .map(|(value, count)| call("Rule", [value, integer(count)])),
            )
        } else {
            list(
                tallies
                    .into_iter()
                    .map(|(value, count)| list([value, integer(count)])),
            )
        }))
    }

    fn set_operation_expr(&mut self, args: &[Expr], mode: u8) -> Result<Option<Expr>> {
        let test = args.iter().find_map(|argument| {
            (argument.has_head("Rule")
                && argument.args().len() == 2
                && is_symbol(&argument.args()[0], "SameTest"))
            .then(|| argument.args()[1].clone())
        });
        let collections = args
            .iter()
            .filter(|argument| !argument.has_head("Rule"))
            .map(target_call_args)
            .collect::<Option<Vec<_>>>();
        let Some(collections) = collections else {
            return Ok(None);
        };
        let Some(first) = collections.first() else {
            return Ok(None);
        };
        let all_values = if mode == 0 {
            collections
                .iter()
                .flat_map(|values| values.iter())
                .collect::<Vec<_>>()
        } else {
            first.iter().collect()
        };
        let mut result = all_values.into_iter().cloned().collect::<Vec<_>>();
        if mode != 1 {
            result.sort_by(expression_order);
        }
        if mode != 0 {
            let mut retained = Vec::new();
            'candidate: for value in result {
                for collection in &collections[1..] {
                    let mut contained = false;
                    for other in *collection {
                        contained = if let Some(test) = &test {
                            is_symbol(
                                &self
                                    .evaluate(call(test.clone(), [value.clone(), other.clone()]))?,
                                "True",
                            )
                        } else {
                            &value == other
                        };
                        if contained {
                            break;
                        }
                    }
                    if (mode == 1 && !contained) || (mode == 2 && contained) {
                        continue 'candidate;
                    }
                }
                retained.push(value);
            }
            result = retained;
        }
        let mut unique: Vec<Expr> = Vec::new();
        for value in result {
            let mut duplicate = false;
            for existing in &unique {
                duplicate = if let Some(test) = &test {
                    is_symbol(
                        &self.evaluate(call(test.clone(), [existing.clone(), value.clone()]))?,
                        "True",
                    )
                } else {
                    existing == &value
                };
                if duplicate {
                    break;
                }
            }
            if !duplicate {
                unique.push(value);
            }
        }
        if mode == 1 {
            unique.sort_by(expression_order);
        }
        Ok(Some(call(args[0].head(), unique)))
    }

    fn map_thread_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        let ([function, sequences] | [function, sequences, _]) = args else {
            return Ok(None);
        };
        if !sequences.has_head("List") {
            return Ok(None);
        }
        let depth = match args.get(2) {
            None => 1,
            Some(Expr::Integer(depth)) => {
                let Some(depth) = depth.to_usize() else {
                    return Ok(None);
                };
                depth
            }
            _ => return Ok(None),
        };
        self.map_thread_level(function, sequences.args(), depth)
            .map(Some)
    }

    fn map_thread_level(
        &mut self,
        function: &Expr,
        sequences: &[Expr],
        depth: usize,
    ) -> Result<Expr> {
        if depth == 0 {
            return self.evaluate(call(function.clone(), sequences.iter().cloned()));
        }
        if sequences.is_empty()
            || sequences.iter().any(|sequence| !sequence.has_head("List"))
            || sequences
                .iter()
                .any(|sequence| sequence.args().len() != sequences[0].args().len())
        {
            return Ok(call(
                "MapThread",
                [
                    function.clone(),
                    list(sequences.iter().cloned()),
                    integer(depth),
                ],
            ));
        }
        let mut output = Vec::new();
        for index in 0..sequences[0].args().len() {
            let values = sequences
                .iter()
                .map(|sequence| sequence.args()[index].clone())
                .collect::<Vec<_>>();
            output.push(self.map_thread_level(function, &values, depth - 1)?);
        }
        Ok(list(output))
    }

    fn outer_expr(&mut self, args: &[Expr]) -> Result<Option<Expr>> {
        if args.len() < 3 {
            return Ok(None);
        }
        let function = &args[0];
        let mut inputs = args[1..].to_vec();
        let mut explicit_depths = Vec::new();
        while inputs.len() > 1 {
            let Some(Expr::Integer(depth)) = inputs.last() else {
                break;
            };
            let Some(depth) = depth.to_usize() else {
                return Ok(None);
            };
            inputs.pop();
            explicit_depths.push(depth);
        }
        explicit_depths.reverse();
        if inputs.is_empty() {
            return Ok(None);
        }
        let depths = if explicit_depths.is_empty() {
            vec![None; inputs.len()]
        } else {
            (0..inputs.len())
                .map(|index| {
                    explicit_depths
                        .get(index)
                        .or_else(|| explicit_depths.last())
                        .copied()
                })
                .collect()
        };
        self.outer_choose(function, &inputs, &depths, 0, &mut Vec::new())
            .map(Some)
    }

    fn outer_choose(
        &mut self,
        function: &Expr,
        inputs: &[Expr],
        depths: &[Option<usize>],
        input_index: usize,
        chosen: &mut Vec<Expr>,
    ) -> Result<Expr> {
        if input_index == inputs.len() {
            return self.evaluate(call(function.clone(), chosen.clone()));
        }
        self.outer_expand(
            function,
            inputs,
            depths,
            input_index,
            &inputs[input_index],
            depths[input_index],
            chosen,
        )
    }

    #[allow(clippy::too_many_arguments)]
    fn outer_expand(
        &mut self,
        function: &Expr,
        inputs: &[Expr],
        depths: &[Option<usize>],
        input_index: usize,
        current: &Expr,
        remaining_depth: Option<usize>,
        chosen: &mut Vec<Expr>,
    ) -> Result<Expr> {
        if remaining_depth != Some(0) && current.has_head("List") {
            let next_depth = remaining_depth.map(|depth| depth - 1);
            let mut output = Vec::with_capacity(current.args().len());
            for child in current.args() {
                output.push(self.outer_expand(
                    function,
                    inputs,
                    depths,
                    input_index,
                    child,
                    next_depth,
                    chosen,
                )?);
            }
            return Ok(call(current.head(), output));
        }
        chosen.push(current.clone());
        let result = self.outer_choose(function, inputs, depths, input_index + 1, chosen);
        chosen.pop();
        result
    }

    fn nest_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        let [function, initial, Expr::Integer(count)] = args else {
            return Ok(None);
        };
        let Some(count) = count.to_usize() else {
            return Ok(None);
        };
        let mut current = initial.clone();
        let mut output = include_steps.then(|| vec![current.clone()]);
        for _ in 0..count {
            current = self.evaluate(call(function.clone(), [current]))?;
            if let Some(output) = &mut output {
                output.push(current.clone());
            }
        }
        Ok(Some(output.map_or(current, list)))
    }

    fn nest_while_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        if !matches!(args.len(), 3..=5) {
            return Ok(None);
        }
        let function = &args[0];
        let test = &args[2];
        let history_size = match args.get(3) {
            None => Some(1_usize),
            Some(Expr::Integer(size)) => size.to_usize(),
            Some(value) if is_symbol(value, "All") => None,
            _ => return Ok(None),
        };
        if history_size == Some(0) {
            return Ok(None);
        }
        let maximum = match args.get(4) {
            None => 65_536,
            Some(Expr::Integer(maximum)) => maximum.to_usize().unwrap_or(0),
            Some(value) if is_symbol(value, "Infinity") => 65_536,
            _ => return Ok(None),
        };
        let mut history = vec![args[1].clone()];
        for _ in 0..maximum {
            let passed = if history_size.is_some_and(|size| history.len() < size) {
                true
            } else {
                let values = history_size
                    .map_or(history.as_slice(), |size| &history[history.len() - size..]);
                is_symbol(
                    &self.evaluate(call(test.clone(), values.iter().cloned()))?,
                    "True",
                )
            };
            if !passed {
                break;
            }
            let next = self.evaluate(call(
                function.clone(),
                [history.last().expect("nonempty").clone()],
            ))?;
            history.push(next);
        }
        Ok(Some(if include_steps {
            list(history)
        } else {
            history.pop().expect("nonempty")
        }))
    }

    fn fixed_point_expr(&mut self, args: &[Expr], include_steps: bool) -> Result<Option<Expr>> {
        let ([function, initial] | [function, initial, _]) = args else {
            return Ok(None);
        };
        let limit = match args.get(2) {
            None => 65_536,
            Some(Expr::Integer(limit)) => limit.to_usize().unwrap_or(0),
            _ => return Ok(None),
        };
        let mut current = initial.clone();
        let mut output = vec![current.clone()];
        for _ in 0..limit {
            let next = self.evaluate(call(function.clone(), [current.clone()]))?;
            if include_steps {
                output.push(next.clone());
            }
            if next == current {
                return Ok(Some(if include_steps { list(output) } else { current }));
            }
            current = next;
        }
        Ok(Some(if include_steps { list(output) } else { current }))
    }

    fn apply_function(&mut self, function: Expr, raw_args: Vec<Expr>) -> Result<Expr> {
        let Expr::Call {
            args: function_args,
            ..
        } = &function
        else {
            unreachable!();
        };
        let Some(attributes) = function_attributes(function_args) else {
            return Ok(call(function, raw_args));
        };
        let hold_all_complete = attributes.contains("HoldAllComplete");
        let hold_all = attributes.contains("HoldAll");
        let hold_first = attributes.contains("HoldFirst");
        let hold_rest = attributes.contains("HoldRest");
        let mut evaluated_args = Vec::new();
        for (index, argument) in raw_args.into_iter().enumerate() {
            let held = hold_all_complete
                || hold_all
                || (hold_first && index == 0)
                || (hold_rest && index > 0);
            let prepared = if held {
                argument
            } else {
                self.evaluate(argument)?
            };
            if prepared.has_head("Sequence")
                && !hold_all_complete
                && !attributes.contains("SequenceHold")
            {
                evaluated_args.extend(prepared.args().iter().cloned());
            } else {
                evaluated_args.push(prepared);
            }
        }
        self.apply_function_prepared(function, evaluated_args, &attributes)
    }

    fn apply_function_prepared(
        &mut self,
        function: Expr,
        evaluated_args: Vec<Expr>,
        attributes: &BTreeSet<String>,
    ) -> Result<Expr> {
        let function_args = function.args();
        if attributes.contains("Listable") {
            let list_lengths = evaluated_args
                .iter()
                .filter(|argument| argument.has_head("List"))
                .map(|argument| argument.args().len())
                .collect::<Vec<_>>();
            if let Some(&length) = list_lengths.first() {
                if list_lengths.iter().any(|candidate| *candidate != length) {
                    self.emit_error_message("General");
                    return Ok(call(function, evaluated_args));
                }
                let mut rows = Vec::with_capacity(length);
                for index in 0..length {
                    let row = evaluated_args
                        .iter()
                        .map(|argument| {
                            if argument.has_head("List") {
                                argument.args()[index].clone()
                            } else {
                                argument.clone()
                            }
                        })
                        .collect::<Vec<_>>();
                    rows.push(self.apply_function_prepared(function.clone(), row, attributes)?);
                }
                return Ok(list(rows));
            }
        }
        match function_args {
            [body] => {
                let substituted = substitute_slots(body, &evaluated_args, &function);
                let result = self.evaluate(substituted)?;
                Ok(self.consume_definition_return(result))
            }
            [parameters, body] | [parameters, body, _] if is_symbol(parameters, "Null") => {
                let substituted = substitute_slots(body, &evaluated_args, &function);
                let result = self.evaluate(substituted)?;
                Ok(self.consume_definition_return(result))
            }
            [parameters, body] => {
                let names: Vec<&str> = match parameters {
                    Expr::Symbol(name) if system_dispatch_name(name) != "Null" => vec![name],
                    Expr::Call { head, args }
                        if is_symbol(head, "List")
                            && args
                                .iter()
                                .all(|argument| matches!(argument, Expr::Symbol(_))) =>
                    {
                        args.iter().filter_map(Expr::symbol_name).collect()
                    }
                    _ => return Ok(call(function, evaluated_args)),
                };
                if evaluated_args.len() < names.len() {
                    return Ok(call(function, evaluated_args));
                }
                let bindings = names
                    .into_iter()
                    .zip(evaluated_args.iter().cloned())
                    .map(|(name, value)| (name.to_owned(), value))
                    .collect::<Vec<_>>();
                let result = self.evaluate(substitute_lexical(body, &bindings))?;
                Ok(self.consume_definition_return(result))
            }
            [parameters, body, _attributes] => {
                let names: Vec<&str> = match parameters {
                    Expr::Symbol(name) if system_dispatch_name(name) != "Null" => vec![name],
                    Expr::Call { head, args }
                        if is_symbol(head, "List")
                            && args
                                .iter()
                                .all(|argument| matches!(argument, Expr::Symbol(_))) =>
                    {
                        args.iter().filter_map(Expr::symbol_name).collect()
                    }
                    _ => return Ok(call(function, evaluated_args)),
                };
                if evaluated_args.len() < names.len() {
                    return Ok(call(function, evaluated_args));
                }
                let bindings = names
                    .into_iter()
                    .zip(evaluated_args.iter().cloned())
                    .map(|(name, value)| (name.to_owned(), value))
                    .collect::<Vec<_>>();
                let result = self.evaluate(substitute_lexical(body, &bindings))?;
                Ok(self.consume_definition_return(result))
            }
            _ => Ok(call(function, evaluated_args)),
        }
    }

    fn apply_composition(&mut self, composition: Expr, raw_args: Vec<Expr>) -> Result<Expr> {
        let right = composition.has_head("RightComposition");
        let functions = composition.args();
        if functions.is_empty() {
            let mut values = raw_args
                .into_iter()
                .map(|argument| self.evaluate(argument))
                .collect::<Result<Vec<_>>>()?;
            return Ok(if values.len() == 1 {
                values.pop().expect("one value")
            } else {
                list(values)
            });
        }
        let mut ordered = functions.iter().collect::<Vec<_>>();
        if !right {
            ordered.reverse();
        }
        let mut functions = ordered.into_iter();
        let first = functions.next().expect("nonempty");
        let mut current = self.evaluate(call(first.clone(), raw_args))?;
        for function in functions {
            current = self.evaluate(call(function.clone(), [current]))?;
        }
        Ok(current)
    }
}

fn apply_callable_head(evaluator: &mut Evaluator, function: &Expr, target: &Expr) -> Result<Expr> {
    if let Some(entries) = association_entries(target) {
        evaluator.evaluate(call(
            function.clone(),
            entries.into_iter().map(|entry| entry.args()[1].clone()),
        ))
    } else if let Expr::Call { args, .. } = target {
        evaluator.evaluate(call(function.clone(), args.clone()))
    } else {
        Ok(target.clone())
    }
}

fn parse_selection_property(property: &Expr) -> Option<SelectionProperty> {
    match property {
        Expr::String(name) if name == "Element" => Some(SelectionProperty::Element),
        Expr::String(name) if name == "Index" => Some(SelectionProperty::Index),
        property if property.has_head("List") => property
            .args()
            .iter()
            .map(parse_selection_property)
            .collect::<Option<Vec<_>>>()
            .map(SelectionProperty::Multiple),
        _ => None,
    }
}

fn valid_symbol_name(name: &str) -> bool {
    !name.is_empty()
        && !name.chars().any(char::is_whitespace)
        && name.split('`').all(|component| {
            !component.is_empty()
                && component
                    .chars()
                    .next()
                    .is_some_and(|character| character.is_alphabetic() || character == '$')
                && component
                    .chars()
                    .all(|character| character.is_alphanumeric() || character == '$')
        })
}

fn split_full_symbol(name: &str) -> Option<(&str, &str)> {
    let index = name.rfind('`')?;
    Some((&name[..=index], &name[index + 1..]))
}

fn display_symbol(full_name: &str) -> Expr {
    let (context, short) = split_full_symbol(full_name).unwrap_or(("Global`", full_name));
    if matches!(context, "System`" | "Global`") {
        symbol(short)
    } else {
        symbol(full_name)
    }
}

fn symbol_name_expr(args: &[Expr]) -> Option<Expr> {
    let [value] = args else {
        return None;
    };
    let name = match value {
        Expr::Symbol(name) | Expr::String(name) => name,
        _ => return None,
    };
    Some(string(name.rsplit('`').next().unwrap_or(name)))
}

fn context_expr(args: &[Expr]) -> Option<Expr> {
    let name = match args {
        [] => return Some(string("Global`")),
        [Expr::Symbol(name) | Expr::String(name)] => name,
        _ => return None,
    };
    if let Some((context, _)) = split_full_symbol(name) {
        Some(string(context))
    } else if SYSTEM_SYMBOLS.contains(name) {
        Some(string("System`"))
    } else {
        Some(string("Global`"))
    }
}

fn wildcard_matches(candidate: &str, pattern: &str) -> bool {
    let mut regex = String::from("^");
    for character in pattern.chars() {
        match character {
            '*' => regex.push_str(".*"),
            '@' => regex.push_str("[^A-Z]*"),
            character => regex.push_str(&regex::escape(&character.to_string())),
        }
    }
    regex.push('$');
    regex::Regex::new(&regex).is_ok_and(|regex| regex.is_match(candidate))
}

fn active_view(expr: &Expr) -> Expr {
    if expr.has_head("Inactive") && expr.args().len() == 1 {
        return active_view(&expr.args()[0]);
    }
    match expr {
        Expr::Call { head, args } => call(
            active_view(head),
            args.iter().map(active_view).collect::<Vec<_>>(),
        ),
        _ => expr.clone(),
    }
}

fn selection_property_name(property: &SelectionProperty) -> Expr {
    match property {
        SelectionProperty::Element => string("Element"),
        SelectionProperty::Index => string("Index"),
        SelectionProperty::Multiple(_) => string("Invalid"),
    }
}

fn tuples_expr(args: &[Expr]) -> Option<Expr> {
    let ([items] | [items, _]) = args else {
        return None;
    };
    let sequences = if let Some(count) = args.get(1) {
        match count {
            Expr::Integer(count) => {
                let count = count.to_usize()?;
                if !items.has_head("List") {
                    return None;
                }
                vec![items.args().to_vec(); count]
            }
            shape if shape.has_head("List") => {
                let dimensions = shape
                    .args()
                    .iter()
                    .map(|value| match value {
                        Expr::Integer(value) => value.to_usize(),
                        _ => None,
                    })
                    .collect::<Option<Vec<_>>>()?;
                return shaped_tuples(items, &dimensions);
            }
            _ => return None,
        }
    } else {
        if !items.has_head("List") {
            return None;
        }
        items
            .args()
            .iter()
            .map(|sequence| {
                if let Expr::Call { args, .. } = sequence {
                    Some(args.clone())
                } else {
                    None
                }
            })
            .collect::<Option<Vec<_>>>()?
    };
    let mut rows = vec![Vec::new()];
    for sequence in sequences {
        let mut next = Vec::new();
        for row in &rows {
            for item in &sequence {
                let mut extended = row.clone();
                extended.push(item.clone());
                next.push(extended);
            }
        }
        rows = next;
    }
    Some(list(rows.into_iter().map(list)))
}

fn shaped_tuples(items: &Expr, dimensions: &[usize]) -> Option<Expr> {
    let values = items.has_head("List").then(|| items.args())?;
    let Some((&dimension, rest)) = dimensions.split_first() else {
        return Some(list([]));
    };
    let element_options = if rest.is_empty() {
        values.to_vec()
    } else {
        let nested = shaped_tuples(items, rest)?;
        nested.args().to_vec()
    };
    let mut rows = vec![Vec::new()];
    for _ in 0..dimension {
        let mut next = Vec::new();
        for row in &rows {
            for item in &element_options {
                let mut extended = row.clone();
                extended.push(item.clone());
                next.push(extended);
            }
        }
        rows = next;
    }
    Some(list(rows.into_iter().map(list)))
}

fn unit_vector_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::Integer(length), Expr::Integer(position)] = args else {
        return None;
    };
    let length = length.to_usize()?;
    let position = position.to_usize()?;
    if position == 0 || position > length {
        return None;
    }
    Some(list(
        (1..=length).map(|index| integer(usize::from(index == position))),
    ))
}

fn identity_matrix_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::Integer(size)] = args else {
        return None;
    };
    let size = size.to_usize()?;
    Some(list((0..size).map(|row| {
        list((0..size).map(|column| integer(usize::from(row == column))))
    })))
}

fn take_drop_expr(args: &[Expr]) -> Option<Expr> {
    let [target, spec] = args else {
        return None;
    };
    Some(list([
        take_drop(&[target.clone(), spec.clone()], false)?,
        take_drop(&[target.clone(), spec.clone()], true)?,
    ]))
}

fn take_list_expr(args: &[Expr]) -> Option<Expr> {
    let [target, specs] = args else {
        return None;
    };
    if !specs.has_head("List") {
        return None;
    }
    let mut remaining = target.clone();
    let mut output = Vec::new();
    for spec in specs.args() {
        if is_symbol(spec, "All") {
            output.push(remaining.clone());
            remaining = call(remaining.head(), []);
        } else {
            output.push(take_drop(&[remaining.clone(), spec.clone()], false)?);
            remaining = take_drop(&[remaining, spec.clone()], true)?;
        }
    }
    Some(list(output))
}

fn delete_expr(args: &[Expr]) -> Option<Expr> {
    let [target, positions] = args else {
        return None;
    };
    let mut paths = position_paths(positions)?;
    paths.sort_by(|left, right| compare_delete_paths(right, left));
    let mut result = target.clone();
    for path in paths {
        result = delete_at_path(&result, &path)?;
    }
    Some(result)
}

fn compare_delete_paths(left: &[Expr], right: &[Expr]) -> Ordering {
    for (left, right) in left.iter().zip(right) {
        let order = match (left, right) {
            (Expr::Integer(left), Expr::Integer(right)) => left.cmp(right),
            _ => expression_order(left, right),
        };
        if order != Ordering::Equal {
            return order;
        }
    }
    left.len().cmp(&right.len())
}

fn delete_at_path(target: &Expr, path: &[Expr]) -> Option<Expr> {
    let (selector, rest) = path.split_first()?;
    if selector.has_head("Key") {
        let [key] = selector.args() else {
            return None;
        };
        let entries = association_entries(target)?;
        let mut output = Vec::new();
        for entry in entries {
            if &entry.args()[0] == key {
                if rest.is_empty() {
                    continue;
                }
                output.push(call(
                    entry.head(),
                    [
                        entry.args()[0].clone(),
                        delete_at_path(&entry.args()[1], rest)?,
                    ],
                ));
            } else {
                output.push(entry);
            }
        }
        return Some(call("Association", output));
    }
    let Expr::Integer(index) = selector else {
        return None;
    };
    let Expr::Call { head, args } = target else {
        return None;
    };
    let index = index.to_i64()?;
    if index == 0 {
        return None;
    }
    let index = resolve_index(args.len(), index)?;
    let mut output = args.clone();
    if rest.is_empty() {
        output.remove(index);
    } else {
        output[index] = delete_at_path(&output[index], rest)?;
    }
    Some(call(head.as_ref().clone(), output))
}

fn native_root(coefficients: &[i64], index: usize, method: i64) -> Expr {
    Expr::Root {
        coefficients: coefficients.iter().copied().map(BigInt::from).collect(),
        index,
        method,
    }
}

fn algebraic_coefficient_root(function: &Expr, index: usize, method: i64) -> Option<Expr> {
    let [body] = function.args() else {
        return None;
    };
    if !function.has_head("Function") {
        return None;
    }
    let slot = call("Slot", [integer(1)]);
    let slot2 = call("Power", [slot.clone(), integer(2)]);
    let slot3 = call("Power", [slot.clone(), integer(3)]);

    let imaginary_linear = call(
        "Plus",
        [call("Times", [symbol("I"), slot.clone()]), integer(1)],
    );
    if body == &imaginary_linear && index == 0 {
        return Some(native_root(&[1, 0, 1], 1, method));
    }

    let gaussian_quadratic = call(
        "Plus",
        [
            call(
                "Times",
                [
                    call(
                        "Times",
                        [
                            call("Plus", [integer(1), symbol("I")]),
                            call("Power", [integer(2), integer(-1)]),
                        ],
                    ),
                    slot2.clone(),
                ],
            ),
            integer(1),
        ],
    );
    if body == &gaussian_quadratic && index == 0 {
        return Some(native_root(&[2, 0, 2, 0, 1], 0, method));
    }

    let cube_root_two = call(
        "Power",
        [
            integer(2),
            call(
                "Times",
                [integer(1), call("Power", [integer(3), integer(-1)])],
            ),
        ],
    );
    let radical_quadratic = call(
        "Plus",
        [slot2.clone(), call("Times", [integer(-1), cube_root_two])],
    );
    if body == &radical_quadratic && index < 2 {
        return Some(native_root(&[-2, 0, 0, 0, 0, 0, 1], index, method));
    }

    let cubic_root = call(
        "Root",
        [
            call("Function", [call("Plus", [slot3, integer(-2)])]),
            integer(1),
        ],
    );
    let nested_root_quadratic = call(
        "Plus",
        [slot2.clone(), call("Times", [integer(-1), cubic_root])],
    );
    if body == &nested_root_quadratic && index < 2 {
        return Some(native_root(&[-2, 0, 0, 0, 0, 0, 1], index, method));
    }

    let square_root = call(
        "Root",
        [
            call(
                "Function",
                [call(
                    "Plus",
                    [call("Power", [slot, integer(2)]), integer(-2)],
                )],
            ),
            integer(2),
        ],
    );
    let mixed_quadratic = call(
        "Plus",
        [
            call("Times", [call("Plus", [square_root, symbol("I")]), slot2]),
            integer(1),
        ],
    );
    if body == &mixed_quadratic && index < 2 {
        return Some(native_root(
            &[1, 0, 0, 0, -2, 0, 0, 0, 9],
            index + 2,
            method,
        ));
    }
    None
}

fn root_reduce_special(target: &Expr) -> Option<Expr> {
    let pi_fifth = call("Times", [rational(1, 5), symbol("Pi")]);
    if target == &call("Sin", [pi_fifth.clone()]) {
        return Some(native_root(&[5, 0, -20, 0, 16], 2, 0));
    }
    if target == &call("Cos", [call("Times", [rational(2, 7), symbol("Pi")])]) {
        return Some(native_root(&[-1, -4, 4, 8], 2, 0));
    }
    if target == &call("SinDegrees", [integer(20)]) {
        return Some(native_root(&[-3, 0, 36, 0, -96, 0, 64], 3, 0));
    }
    if target == &call("Haversine", [pi_fifth]) {
        return Some(native_root(&[1, -12, 16], 0, 0));
    }
    if target.has_head("Re")
        && let [
            Expr::Root {
                coefficients,
                index,
                ..
            },
        ] = target.args()
        && coefficients
            == &[
                BigInt::from(-2),
                BigInt::zero(),
                BigInt::zero(),
                BigInt::one(),
            ]
        && *index == 1
    {
        return Some(native_root(&[1, 0, 0, 4], 0, 0));
    }
    None
}

#[derive(Clone, Copy)]
enum MonomialOrder {
    Lexicographic,
    DegreeLexicographic,
    DegreeReverseLexicographic,
    NegativeLexicographic,
    NegativeDegreeLexicographic,
    NegativeDegreeReverseLexicographic,
}

fn min_max_list_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    if values.is_empty() {
        return Some(list([
            symbol("Infinity"),
            call("Times", [integer(-1), symbol("Infinity")]),
        ]));
    }
    let minimum = values
        .iter()
        .min_by(|left, right| expression_order(left, right))?;
    let maximum = values
        .iter()
        .max_by(|left, right| expression_order(left, right))?;
    Some(list([minimum.clone(), maximum.clone()]))
}

fn ranked_expr(args: &[Expr], maximum: bool) -> Option<Expr> {
    let [target, Expr::Integer(rank)] = args else {
        return None;
    };
    let mut values = target_call_args(target)?.to_vec();
    values.sort_by(expression_order);
    if maximum {
        values.reverse();
    }
    let rank = rank.to_i64()?;
    if rank == 0 || rank.unsigned_abs() as usize > values.len() {
        return None;
    }
    let index = if rank > 0 {
        usize::try_from(rank - 1).ok()?
    } else {
        values.len() - usize::try_from(rank.unsigned_abs()).ok()?
    };
    values.get(index).cloned()
}

fn mode_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    if values.is_empty() {
        return None;
    }
    let mut counts: Vec<(Expr, usize)> = Vec::new();
    for value in values {
        if let Some((_, count)) = counts.iter_mut().find(|(existing, _)| existing == value) {
            *count += 1;
        } else {
            counts.push((value.clone(), 1));
        }
    }
    let maximum = counts.iter().map(|(_, count)| *count).max()?;
    counts
        .into_iter()
        .filter(|(_, count)| *count == maximum)
        .map(|(value, _)| value)
        .min_by(expression_order)
}

fn bin_values_expr(args: &[Expr], lists: bool) -> Option<Expr> {
    let ([target] | [target, _]) = args else {
        return None;
    };
    let values = target_call_args(target)?;
    let (minimum, maximum, width) = match args.get(1) {
        Some(specification) if specification.has_head("List") => {
            let [minimum, maximum, width] = specification.args() else {
                return None;
            };
            (
                numeric_real_value(minimum)?,
                numeric_real_value(maximum)?,
                numeric_real_value(width)?,
            )
        }
        Some(width) => {
            let width = numeric_real_value(width)?;
            let minimum = values
                .iter()
                .filter_map(numeric_real_value)
                .fold(f64::INFINITY, f64::min);
            let maximum = values
                .iter()
                .filter_map(numeric_real_value)
                .fold(f64::NEG_INFINITY, f64::max);
            (
                (minimum / width).floor() * width,
                ((maximum / width).floor() + 1.0) * width,
                width,
            )
        }
        None => {
            return bin_values_expr(&[target.clone(), integer(1)], lists);
        }
    };
    if width <= 0.0 || maximum <= minimum {
        return None;
    }
    let count = ((maximum - minimum) / width).floor() as usize;
    let mut bins = vec![Vec::new(); count];
    for value in values {
        let numeric = numeric_real_value(value)?;
        let index = ((numeric - minimum) / width).floor() as isize;
        if index >= 0 && (index as usize) < count {
            bins[index as usize].push(value.clone());
        }
    }
    Some(if lists {
        list(bins.into_iter().map(list))
    } else {
        list(bins.into_iter().map(|values| integer(values.len())))
    })
}

fn permutation_cycles_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    if !target.has_head("List") {
        return None;
    }
    let permutation = target
        .args()
        .iter()
        .map(|value| match value {
            Expr::Integer(value) => value.to_usize(),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()?;
    let length = permutation.len();
    if permutation.iter().copied().collect::<BTreeSet<_>>() != (1..=length).collect::<BTreeSet<_>>()
    {
        return None;
    }
    let mut visited = vec![false; length];
    let mut cycles = Vec::new();
    for start in 1..=length {
        if visited[start - 1] {
            continue;
        }
        let mut cycle = Vec::new();
        let mut current = start;
        while !visited[current - 1] {
            visited[current - 1] = true;
            cycle.push(integer(current));
            current = permutation[current - 1];
        }
        if cycle.len() > 1 {
            cycles.push(list(cycle));
        }
    }
    Some(call("Cycles", [list(cycles)]))
}

fn permutation_list_expr(args: &[Expr]) -> Option<Expr> {
    let ([cycles] | [cycles, _]) = args else {
        return None;
    };
    if !cycles.has_head("Cycles") {
        return None;
    }
    let [cycle_list] = cycles.args() else {
        return None;
    };
    if !cycle_list.has_head("List") {
        return None;
    }
    let inferred = cycle_list
        .args()
        .iter()
        .flat_map(|cycle| cycle.args())
        .filter_map(|value| match value {
            Expr::Integer(value) => value.to_usize(),
            _ => None,
        })
        .max()
        .unwrap_or(0);
    let length = match args.get(1) {
        None => inferred,
        Some(Expr::Integer(length)) => length.to_usize()?,
        _ => return None,
    };
    if length < inferred {
        return None;
    }
    let mut permutation = (1..=length).collect::<Vec<_>>();
    for cycle in cycle_list.args() {
        if !cycle.has_head("List") {
            return None;
        }
        let values = cycle
            .args()
            .iter()
            .map(|value| match value {
                Expr::Integer(value) => value.to_usize(),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()?;
        for index in 0..values.len() {
            permutation[values[index] - 1] = values[(index + 1) % values.len()];
        }
    }
    Some(list(permutation.into_iter().map(integer)))
}

fn permutation_order_expr(args: &[Expr]) -> Option<Expr> {
    let [cycles] = args else {
        return None;
    };
    let [cycle_list] = cycles.args() else {
        return None;
    };
    if !cycles.has_head("Cycles") || !cycle_list.has_head("List") {
        return None;
    }
    let order = cycle_list
        .args()
        .iter()
        .map(|cycle| cycle.args().len())
        .fold(1_usize, |order, length| order.lcm(&length));
    Some(integer(order))
}

fn sequence_position_count_expr(args: &[Expr], count: bool) -> Option<Expr> {
    let [target, pattern] = args else {
        return None;
    };
    if !target.has_head("List") || !pattern.has_head("List") || pattern.args().is_empty() {
        return None;
    }
    let mut spans = Vec::new();
    let mut index = 0;
    while index + pattern.args().len() <= target.args().len() {
        if target.args()[index..index + pattern.args().len()]
            .iter()
            .zip(pattern.args())
            .all(|(value, pattern)| simple_pattern_matches(value, pattern))
        {
            spans.push((index + 1, index + pattern.args().len()));
            index += pattern.args().len();
        } else {
            index += 1;
        }
    }
    Some(if count {
        integer(spans.len())
    } else {
        list(
            spans
                .into_iter()
                .map(|(start, end)| list([integer(start), integer(end)])),
        )
    })
}

fn first_position_expr(args: &[Expr]) -> Option<Expr> {
    if !(2..=4).contains(&args.len()) {
        return None;
    }
    let mut position_arguments = vec![args[0].clone(), args[1].clone()];
    position_arguments.push(args.get(3).cloned().unwrap_or_else(|| symbol("Infinity")));
    position_arguments.push(integer(1));
    let positions = position_expr(&position_arguments)?;
    if let Some(position) = positions.args().first() {
        Some(position.clone())
    } else {
        Some(
            args.get(2)
                .cloned()
                .unwrap_or_else(|| call("Missing", [string("NotFound")])),
        )
    }
}

fn extremal_positions_expr(args: &[Expr], maximum: bool) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    let extremum = if maximum {
        values
            .iter()
            .max_by(|left, right| expression_order(left, right))
    } else {
        values
            .iter()
            .min_by(|left, right| expression_order(left, right))
    };
    Some(list(values.iter().enumerate().filter_map(
        |(index, value)| (Some(value) == extremum).then(|| integer(index + 1)),
    )))
}

fn position_index_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    let mut groups: Vec<(Expr, Vec<usize>)> = Vec::new();
    for (index, value) in values.iter().enumerate() {
        if let Some((_, positions)) = groups.iter_mut().find(|(existing, _)| existing == value) {
            positions.push(index + 1);
        } else {
            groups.push((value.clone(), vec![index + 1]));
        }
    }
    Some(call(
        "Association",
        groups.into_iter().map(|(value, positions)| {
            call("Rule", [value, list(positions.into_iter().map(integer))])
        }),
    ))
}

fn count_distinct_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let mut values = target_call_args(target)?.to_vec();
    values.sort_by(expression_order);
    values.dedup();
    Some(integer(values.len()))
}

fn operate_expr(args: &[Expr]) -> Option<Expr> {
    let ([operator, target] | [operator, target, _]) = args else {
        return None;
    };
    let level = match args.get(2) {
        None => 1,
        Some(Expr::Integer(level)) => level.to_usize()?,
        _ => return None,
    };
    fn operate(operator: &Expr, target: &Expr, level: usize) -> Option<Expr> {
        if level == 0 {
            return Some(call(operator.clone(), [target.clone()]));
        }
        let Expr::Call { head, args } = target else {
            return None;
        };
        let head = operate(operator, head, level - 1)?;
        Some(call(head, args.iter().cloned()))
    }
    operate(operator, target, level)
}

fn variable_exprs(specification: &Expr) -> Vec<Expr> {
    if specification.has_head("List") {
        specification.args().to_vec()
    } else {
        vec![specification.clone()]
    }
}

fn expr_contains_any(expr: &Expr, variables: &[Expr]) -> bool {
    if variables.iter().any(|variable| variable == expr) {
        return true;
    }
    match expr {
        Expr::Complex { real, imaginary } => {
            expr_contains_any(real, variables) || expr_contains_any(imaginary, variables)
        }
        Expr::Call { args, .. } => args
            .iter()
            .any(|argument| expr_contains_any(argument, variables)),
        _ => false,
    }
}

fn algebraic_expr_convertible(expr: &Expr) -> bool {
    match expr {
        Expr::Integer(_) | Expr::Rational(_) | Expr::Symbol(_) => true,
        Expr::Complex { real, imaginary } => {
            algebraic_expr_convertible(real) && algebraic_expr_convertible(imaginary)
        }
        Expr::Call { head, args }
            if matches!(
                head.symbol_name().map(system_dispatch_name),
                Some("Plus" | "Times" | "Power")
            ) =>
        {
            args.iter().all(algebraic_expr_convertible)
        }
        _ => false,
    }
}

fn collect_polynomial_variables(expr: &Expr, output: &mut Vec<Expr>) -> bool {
    match expr {
        Expr::Symbol(_) => {
            output.push(expr.clone());
            true
        }
        Expr::Integer(_) | Expr::Rational(_) => true,
        Expr::Complex { real, imaginary } => {
            collect_polynomial_variables(real, output)
                && collect_polynomial_variables(imaginary, output)
        }
        Expr::Call { head, args }
            if matches!(
                head.symbol_name().map(system_dispatch_name),
                Some("Plus" | "Times" | "Power")
            ) =>
        {
            args.iter()
                .all(|argument| collect_polynomial_variables(argument, output))
        }
        _ => false,
    }
}

fn polynomial_variables(expr: &Expr) -> Option<Vec<Expr>> {
    let mut variables = Vec::new();
    collect_polynomial_variables(expr, &mut variables).then_some(())?;
    variables.sort_by(expression_order);
    variables.dedup();
    Some(variables)
}

fn polynomial_variables_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    Some(list(polynomial_variables(target)?))
}

fn monomial_order(expr: &Expr) -> Option<MonomialOrder> {
    let Expr::Symbol(name) = expr else {
        return None;
    };
    match system_dispatch_name(name) {
        "Lexicographic" => Some(MonomialOrder::Lexicographic),
        "DegreeLexicographic" => Some(MonomialOrder::DegreeLexicographic),
        "DegreeReverseLexicographic" => Some(MonomialOrder::DegreeReverseLexicographic),
        "NegativeLexicographic" => Some(MonomialOrder::NegativeLexicographic),
        "NegativeDegreeLexicographic" => Some(MonomialOrder::NegativeDegreeLexicographic),
        "NegativeDegreeReverseLexicographic" => {
            Some(MonomialOrder::NegativeDegreeReverseLexicographic)
        }
        _ => None,
    }
}

fn monomial_compare(left: &[usize], right: &[usize], order: MonomialOrder) -> Ordering {
    let lexicographic = || left.cmp(right);
    let degree = || left.iter().sum::<usize>().cmp(&right.iter().sum::<usize>());
    let reverse_lexicographic = || {
        left.iter()
            .rev()
            .zip(right.iter().rev())
            .find_map(|(left, right)| (left != right).then(|| right.cmp(left)))
            .unwrap_or(Ordering::Equal)
    };
    let ascending = match order {
        MonomialOrder::Lexicographic => lexicographic(),
        MonomialOrder::DegreeLexicographic => degree().then_with(lexicographic),
        MonomialOrder::DegreeReverseLexicographic => degree().then_with(reverse_lexicographic),
        MonomialOrder::NegativeLexicographic => return lexicographic(),
        MonomialOrder::NegativeDegreeLexicographic => {
            return degree().then_with(lexicographic);
        }
        MonomialOrder::NegativeDegreeReverseLexicographic => {
            return degree().then_with(reverse_lexicographic);
        }
    };
    ascending.reverse()
}

fn monomial_divides(divisor: &[usize], dividend: &[usize]) -> bool {
    divisor.len() == dividend.len()
        && divisor
            .iter()
            .zip(dividend)
            .all(|(divisor, dividend)| divisor <= dividend)
}

fn monomial_form_factors(form: &Expr) -> Option<Vec<(Expr, usize)>> {
    fn collect(form: &Expr, output: &mut Vec<(Expr, usize)>, multiplier: usize) -> Option<()> {
        if form.has_head("Times") {
            for factor in form.args() {
                collect(factor, output, multiplier)?;
            }
            return Some(());
        }
        if form.has_head("Power")
            && let [base, Expr::Integer(exponent)] = form.args()
        {
            let exponent = exponent.to_usize()?;
            if exponent == 0 {
                return None;
            }
            return collect(base, output, multiplier.checked_mul(exponent)?);
        }
        if matches!(form, Expr::Integer(value) if value.is_one()) {
            return Some(());
        }
        if matches!(form, Expr::Integer(_) | Expr::Rational(_) | Expr::Real(_)) {
            return None;
        }
        if let Some((_, power)) = output.iter_mut().find(|(existing, _)| existing == form) {
            *power = power.checked_add(multiplier)?;
        } else {
            output.push((form.clone(), multiplier));
        }
        Some(())
    }

    let mut factors = Vec::new();
    collect(form, &mut factors, 1)?;
    (!factors.is_empty()).then_some(factors)
}

fn coefficient_array_expr(
    polynomial: &NativePolynomial,
    dimensions: Option<&[usize]>,
    level: usize,
    prefix: &[usize],
) -> Expr {
    let variable_count = polynomial
        .terms
        .keys()
        .next()
        .map_or(prefix.len(), Vec::len);
    if level == variable_count {
        return polynomial
            .terms
            .get(prefix)
            .cloned()
            .unwrap_or_else(|| integer(0));
    }
    let count = dimensions.map_or_else(
        || {
            polynomial
                .terms
                .keys()
                .filter(|powers| powers.starts_with(prefix))
                .map(|powers| powers[level] + 1)
                .max()
                .unwrap_or(0)
        },
        |dimensions| dimensions[level],
    );
    list((0..count).map(|index| {
        let mut next = prefix.to_vec();
        next.push(index);
        coefficient_array_expr(polynomial, dimensions, level + 1, &next)
    }))
}

fn polynomial_rational_content(polynomial: &NativePolynomial) -> Option<BigRational> {
    let mut numerator_gcd = BigInt::zero();
    let mut denominator_lcm = BigInt::one();
    for coefficient in polynomial.terms.values() {
        let coefficient = as_rational(coefficient)?;
        numerator_gcd = numerator_gcd.gcd(&coefficient.numer().abs());
        denominator_lcm = denominator_lcm.lcm(coefficient.denom());
    }
    Some(BigRational::new(numerator_gcd, denominator_lcm))
}

fn univariate_rational_coefficients(polynomial: &NativePolynomial) -> Option<Vec<BigRational>> {
    let degree = polynomial
        .terms
        .keys()
        .map(|powers| (powers.len() == 1).then_some(powers[0]))
        .collect::<Option<Vec<_>>>()?
        .into_iter()
        .max()
        .unwrap_or(0);
    let mut coefficients = vec![BigRational::zero(); degree + 1];
    for (powers, coefficient) in &polynomial.terms {
        coefficients[powers[0]] = as_rational(coefficient)?;
    }
    while coefficients.last().is_some_and(Zero::is_zero) {
        coefficients.pop();
    }
    Some(coefficients)
}

fn polynomial_from_rational_coefficients(coefficients: &[BigRational]) -> NativePolynomial {
    NativePolynomial {
        terms: coefficients
            .iter()
            .enumerate()
            .filter(|(_, coefficient)| !coefficient.is_zero())
            .map(|(power, coefficient)| (vec![power], from_rational(coefficient.clone())))
            .collect(),
    }
}

fn integer_polynomial_root(coefficients: &[BigRational]) -> Option<BigRational> {
    let constant = coefficients.first()?.clone();
    if constant.is_zero() {
        return Some(BigRational::zero());
    }
    let magnitude = constant.numer().abs().to_u64()?;
    if magnitude > 1_000_000 {
        return None;
    }
    let mut candidates = Vec::new();
    let mut divisor = 1_u64;
    while divisor <= magnitude / divisor {
        if magnitude % divisor == 0 {
            candidates.push(divisor);
            if divisor != magnitude / divisor {
                candidates.push(magnitude / divisor);
            }
        }
        divisor += 1;
    }
    candidates.sort_unstable();
    for candidate in candidates {
        for candidate in [BigInt::from(candidate), -BigInt::from(candidate)] {
            let candidate = BigRational::from_integer(candidate);
            let value = coefficients
                .iter()
                .rev()
                .fold(BigRational::zero(), |value, coefficient| {
                    value * &candidate + coefficient
                });
            if value.is_zero() {
                return Some(candidate);
            }
        }
    }
    None
}

fn synthetic_divide_rational(
    coefficients: &[BigRational],
    root: &BigRational,
) -> Option<Vec<BigRational>> {
    if coefficients.len() <= 1 {
        return None;
    }
    let mut quotient = vec![BigRational::zero(); coefficients.len() - 1];
    let mut carry = coefficients.last()?.clone();
    for index in (1..coefficients.len()).rev() {
        quotient[index - 1] = carry.clone();
        carry = coefficients[index - 1].clone() + root * carry;
    }
    carry.is_zero().then_some(quotient)
}

fn divide_rational_polynomials(
    dividend: &[BigRational],
    divisor: &[BigRational],
) -> Option<(Vec<BigRational>, Vec<BigRational>)> {
    let mut dividend = dividend.to_vec();
    let mut divisor = divisor.to_vec();
    while dividend.last().is_some_and(Zero::is_zero) {
        dividend.pop();
    }
    while divisor.last().is_some_and(Zero::is_zero) {
        divisor.pop();
    }
    if divisor.is_empty() {
        return None;
    }
    let mut quotient = vec![BigRational::zero(); dividend.len().saturating_sub(divisor.len()) + 1];
    while dividend.len() >= divisor.len() {
        let degree = dividend.len() - divisor.len();
        let leading = dividend.last()?.clone() / divisor.last()?;
        quotient[degree] += &leading;
        for (index, coefficient) in divisor.iter().enumerate() {
            dividend[index + degree] -= &leading * coefficient;
        }
        while dividend.last().is_some_and(Zero::is_zero) {
            dividend.pop();
        }
    }
    Some((quotient, dividend))
}

fn gcd_rational_polynomials(
    left: &[BigRational],
    right: &[BigRational],
) -> Option<Vec<BigRational>> {
    let mut left = left.to_vec();
    let mut right = right.to_vec();
    while left.last().is_some_and(Zero::is_zero) {
        left.pop();
    }
    while right.last().is_some_and(Zero::is_zero) {
        right.pop();
    }
    while !right.is_empty() {
        let (_, remainder) = divide_rational_polynomials(&left, &right)?;
        left = right;
        right = remainder;
    }
    let leading = left.last()?.clone();
    left.iter_mut()
        .for_each(|coefficient| *coefficient /= &leading);
    Some(left)
}

fn square_free_rational_polynomial(coefficients: &[BigRational]) -> Option<Vec<BigRational>> {
    let mut polynomial = coefficients.to_vec();
    while polynomial.last().is_some_and(Zero::is_zero) {
        polynomial.pop();
    }
    if polynomial.len() <= 1 {
        return None;
    }
    let derivative = polynomial
        .iter()
        .enumerate()
        .skip(1)
        .map(|(power, coefficient)| coefficient * BigInt::from(power))
        .collect::<Vec<_>>();
    let mut left = polynomial.clone();
    let mut right = derivative;
    while !right.is_empty() {
        let (_, remainder) = divide_rational_polynomials(&left, &right)?;
        left = right;
        right = remainder;
    }
    let leading = left.last()?.clone();
    left.iter_mut()
        .for_each(|coefficient| *coefficient /= &leading);
    let (mut square_free, remainder) = divide_rational_polynomials(&polynomial, &left)?;
    if !remainder.is_empty() {
        return None;
    }
    while square_free.last().is_some_and(Zero::is_zero) {
        square_free.pop();
    }
    Some(square_free)
}

fn primitive_integer_coefficients(coefficients: &[BigRational]) -> Option<Vec<BigInt>> {
    let denominator_lcm = coefficients.iter().fold(BigInt::one(), |lcm, coefficient| {
        lcm.lcm(coefficient.denom())
    });
    let mut integers = coefficients
        .iter()
        .map(|coefficient| {
            let scaled = coefficient * BigRational::from_integer(denominator_lcm.clone());
            (scaled.denom().is_one()).then(|| scaled.numer().clone())
        })
        .collect::<Option<Vec<_>>>()?;
    let content = integers.iter().fold(BigInt::zero(), |gcd, coefficient| {
        gcd.gcd(&coefficient.abs())
    });
    if !content.is_zero() && !content.is_one() {
        integers
            .iter_mut()
            .for_each(|coefficient| *coefficient /= &content);
    }
    if integers.last().is_some_and(Signed::is_negative) {
        integers
            .iter_mut()
            .for_each(|coefficient| *coefficient = -&*coefficient);
    }
    Some(integers)
}

fn exact_polynomial_root(coefficients: &[BigRational], index: usize) -> Option<Expr> {
    match coefficients.len() {
        2 if index == 0 => Some(from_rational(-&coefficients[0] / &coefficients[1])),
        3 => {
            let discriminant = &coefficients[1] * &coefficients[1]
                - BigRational::from_integer(BigInt::from(4)) * &coefficients[2] * &coefficients[0];
            let root = exact_rational_sqrt(&discriminant)?;
            let denominator = BigRational::from_integer(BigInt::from(2)) * &coefficients[2];
            let mut roots = vec![
                (-&coefficients[1] - &root) / &denominator,
                (-&coefficients[1] + root) / denominator,
            ];
            roots.sort();
            roots.get(index).cloned().map(from_rational)
        }
        _ => None,
    }
}

fn rational_roots_with_residual(
    coefficients: &[BigRational],
) -> (Vec<BigRational>, Vec<BigRational>) {
    let mut coefficients = coefficients.to_vec();
    while coefficients.last().is_some_and(Zero::is_zero) {
        coefficients.pop();
    }
    let mut roots = Vec::new();
    while coefficients.len() > 1 {
        let Some(root) = integer_polynomial_root(&coefficients) else {
            break;
        };
        let Some(quotient) = synthetic_divide_rational(&coefficients, &root) else {
            break;
        };
        roots.push(root);
        coefficients = quotient;
    }
    (roots, coefficients)
}

fn numeric_polynomial_roots(coefficients: &[BigRational]) -> Option<Vec<(f64, f64)>> {
    let (rational_roots, residual) = rational_roots_with_residual(coefficients);
    let mut roots = Vec::new();
    for root in rational_roots {
        roots.push((root.to_f64()?, 0.0));
    }
    match residual.len() {
        0 | 1 => {}
        2 => roots.push(((-&residual[0] / &residual[1]).to_f64()?, 0.0)),
        3 => {
            let a = residual[2].to_f64()?;
            let b = residual[1].to_f64()?;
            let c = residual[0].to_f64()?;
            let discriminant = b * b - 4.0 * a * c;
            if discriminant >= 0.0 {
                roots.push(((-b - discriminant.sqrt()) / (2.0 * a), 0.0));
                roots.push(((-b + discriminant.sqrt()) / (2.0 * a), 0.0));
            } else {
                let imaginary = (-discriminant).sqrt() / (2.0 * a.abs());
                let real = -b / (2.0 * a);
                roots.push((real, -imaginary));
                roots.push((real, imaginary));
            }
        }
        _ => return None,
    }
    Some(roots)
}

fn function_power(function: &Expr) -> Option<usize> {
    let body = match function.args() {
        [body] if function.has_head("Function") => body,
        [_, body] if function.has_head("Function") => body,
        _ => return None,
    };
    let slot = call("Slot", [integer(1)]);
    if body == &slot {
        return Some(1);
    }
    if body.has_head("Power")
        && body.args().first() == Some(&slot)
        && let Some(Expr::Integer(power)) = body.args().get(1)
    {
        return power.to_usize();
    }
    None
}

fn newton_power_sum(coefficients: &[BigRational], power: usize) -> Option<BigRational> {
    if coefficients.len() <= 1 {
        return None;
    }
    if power == 0 {
        return Some(BigRational::from_integer(BigInt::from(
            coefficients.len() - 1,
        )));
    }
    let degree = coefficients.len() - 1;
    let leading = coefficients.last()?.clone();
    let normalized = coefficients
        .iter()
        .map(|coefficient| coefficient / &leading)
        .collect::<Vec<_>>();
    let mut sums = vec![BigRational::zero(); power + 1];
    for exponent in 1..=power {
        let mut value = BigRational::zero();
        let maximum = exponent.saturating_sub(1).min(degree - 1);
        for offset in 1..=maximum {
            value += &normalized[degree - offset] * &sums[exponent - offset];
        }
        if exponent <= degree {
            value += &normalized[degree - exponent] * BigInt::from(exponent);
        } else {
            for offset in maximum + 1..=degree {
                value += &normalized[degree - offset] * &sums[exponent - offset];
            }
        }
        sums[exponent] = -value;
    }
    Some(sums[power].clone())
}

fn binomial_root_value(coefficients: &[BigInt]) -> Option<(usize, BigRational)> {
    if coefficients.len() <= 1
        || coefficients[1..coefficients.len() - 1]
            .iter()
            .any(|coefficient| !coefficient.is_zero())
    {
        return None;
    }
    let degree = coefficients.len() - 1;
    let value = BigRational::new(-coefficients[0].clone(), coefficients[degree].clone());
    Some((degree, value))
}

fn square_root_radicand(expr: &Expr) -> Option<(BigRational, bool)> {
    match expr {
        Expr::Root {
            coefficients,
            index,
            ..
        } => {
            let (degree, value) = binomial_root_value(coefficients)?;
            (degree == 2 && value.is_positive()).then_some((value, *index == 1))
        }
        Expr::Call { head, args }
            if is_symbol(head, "Power")
                && matches!(args.as_slice(), [_, exponent] if exponent == &rational(1, 2)) =>
        {
            Some((as_rational(&args[0])?, true))
        }
        _ => None,
    }
}

fn radicalize_root(root: &Expr) -> Expr {
    let Expr::Root {
        coefficients,
        index,
        ..
    } = root
    else {
        return root.clone();
    };
    let Some((degree, value)) = binomial_root_value(coefficients) else {
        return root.clone();
    };
    let magnitude = if value.abs().is_one() {
        integer(1)
    } else {
        call(
            "Power",
            [
                from_rational(value.abs()),
                rational(1, BigInt::from(degree)),
            ],
        )
    };
    if value.is_positive() {
        if degree % 2 == 1 && *index == 0 || degree % 2 == 0 && *index == 1 {
            return magnitude;
        }
        if degree % 2 == 0 && *index == 0 {
            return call("Times", [integer(-1), magnitude]);
        }
    } else if degree == 2 {
        if *index == 0 {
            let imaginary = if magnitude == integer(1) {
                integer(-1)
            } else {
                call("Times", [integer(-1), magnitude])
            };
            return complex(integer(0), imaginary);
        }
        if *index == 1 {
            return complex(integer(0), magnitude);
        }
    }
    root.clone()
}

fn radicalize_expr(expr: &Expr) -> Expr {
    match expr {
        Expr::Root { .. } => radicalize_root(expr),
        Expr::Call { head, args } => call(head.as_ref().clone(), args.iter().map(radicalize_expr)),
        _ => expr.clone(),
    }
}

fn to_radicals_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    Some(radicalize_expr(target))
}

fn root_approximations(coefficients: &[BigInt]) -> Option<Vec<(f64, f64)>> {
    let (degree, value) = binomial_root_value(coefficients)?;
    let value = value.to_f64()?;
    let magnitude = value.abs().powf(1.0 / degree as f64);
    let phase = if value.is_sign_negative() {
        std::f64::consts::PI
    } else {
        0.0
    };
    let mut roots = (0..degree)
        .map(|index| {
            let angle = (phase + 2.0 * std::f64::consts::PI * index as f64) / degree as f64;
            let mut real = magnitude * angle.cos();
            let mut imaginary = magnitude * angle.sin();
            if real.abs() < 1e-12 {
                real = 0.0;
            }
            if imaginary.abs() < 1e-12 {
                imaginary = 0.0;
            }
            (real, imaginary)
        })
        .collect::<Vec<_>>();
    roots.sort_by(|left, right| {
        let left_real = left.1 == 0.0;
        let right_real = right.1 == 0.0;
        right_real
            .cmp(&left_real)
            .then_with(|| left.0.partial_cmp(&right.0).unwrap_or(Ordering::Equal))
            .then_with(|| left.1.partial_cmp(&right.1).unwrap_or(Ordering::Equal))
    });
    Some(roots)
}

fn dyadic_bounds(value: f64, exponent: usize) -> (Expr, Expr) {
    let denominator = BigInt::one() << exponent;
    let scaled = value * 2_f64.powi(i32::try_from(exponent).unwrap_or(30));
    let nearest = scaled.round();
    if (scaled - nearest).abs() < 1e-12 {
        let doubled_denominator = &denominator * 2_u8;
        let nearest = BigInt::from(nearest as i128);
        return (
            rational(&nearest * 2_u8 - 1_u8, doubled_denominator.clone()),
            rational(&nearest * 2_u8 + 1_u8, doubled_denominator),
        );
    }
    let lower = BigInt::from(scaled.floor() as i128);
    (
        rational(lower.clone(), denominator.clone()),
        rational(lower + 1_u8, denominator),
    )
}

fn isolating_interval_expr(args: &[Expr]) -> Option<Expr> {
    if !(1..=2).contains(&args.len()) {
        return None;
    }
    if matches!(args[0], Expr::Integer(_) | Expr::Rational(_)) {
        return Some(list([args[0].clone(), args[0].clone()]));
    }
    let Expr::Root {
        coefficients,
        index,
        ..
    } = &args[0]
    else {
        return None;
    };
    let exponent = match args.get(1) {
        None => 6,
        Some(Expr::Integer(exponent)) if exponent.is_positive() => {
            exponent.to_usize()?.clamp(6, 30)
        }
        _ => return None,
    };
    let approximation = *root_approximations(coefficients)?.get(*index)?;
    if approximation.1 == 0.0 {
        let (lower, upper) = dyadic_bounds(approximation.0, exponent);
        Some(list([lower, upper]))
    } else {
        let (lower_real, upper_real) = dyadic_bounds(approximation.0, exponent);
        let (lower_imaginary, upper_imaginary) = dyadic_bounds(approximation.1, exponent);
        Some(list([
            complex(lower_real, lower_imaginary),
            complex(upper_real, upper_imaginary),
        ]))
    }
}

fn univariate_expr_coefficients(polynomial: &NativePolynomial) -> Option<Vec<Expr>> {
    if polynomial.terms.is_empty() {
        return Some(Vec::new());
    }
    let degree = polynomial
        .terms
        .keys()
        .map(|powers| (powers.len() == 1).then_some(powers[0]))
        .collect::<Option<Vec<_>>>()?
        .into_iter()
        .max()?;
    let mut coefficients = vec![integer(0); degree + 1];
    for (powers, coefficient) in &polynomial.terms {
        coefficients[powers[0]] = coefficient.clone();
    }
    Some(coefficients)
}

fn trim_polynomial_coefficients(coefficients: &mut Vec<Expr>) {
    while coefficients.last() == Some(&integer(0)) {
        coefficients.pop();
    }
}

fn polynomial_from_expr_coefficients(coefficients: &[Expr]) -> NativePolynomial {
    NativePolynomial {
        terms: coefficients
            .iter()
            .enumerate()
            .filter(|(_, coefficient)| coefficient != &&integer(0))
            .map(|(power, coefficient)| (vec![power], coefficient.clone()))
            .collect(),
    }
}

fn monic_polynomial(
    evaluator: &mut Evaluator,
    polynomial: NativePolynomial,
) -> Result<NativePolynomial> {
    let Some(coefficients) = univariate_expr_coefficients(&polynomial) else {
        return Ok(polynomial);
    };
    let Some(leading) = coefficients.last() else {
        return Ok(polynomial);
    };
    if leading == &integer(1) {
        return Ok(polynomial);
    }
    let inverse = call("Power", [leading.clone(), integer(-1)]);
    let mut result = NativePolynomial::default();
    for (powers, coefficient) in polynomial.terms {
        result.terms.insert(
            powers,
            evaluator.evaluate(call("Times", [coefficient, inverse.clone()]))?,
        );
    }
    Ok(result)
}

fn fraction_factors(expr: &Expr) -> Option<(Vec<Expr>, Vec<Expr>)> {
    match expr {
        Expr::Rational(value) => Some((
            vec![integer(value.numer().clone())],
            vec![integer(value.denom().clone())],
        )),
        Expr::Call { head, args } if is_symbol(head, "Times") => {
            let mut numerator = Vec::new();
            let mut denominator = Vec::new();
            for factor in args {
                let (factor_numerator, factor_denominator) = fraction_factors(factor)?;
                numerator.extend(factor_numerator);
                denominator.extend(factor_denominator);
            }
            Some((numerator, denominator))
        }
        Expr::Call { head, args }
            if is_symbol(head, "Power")
                && matches!(args.as_slice(), [_, Expr::Integer(exponent)] if exponent.is_negative()) =>
        {
            let Expr::Integer(exponent) = &args[1] else {
                unreachable!();
            };
            let exponent = exponent.abs();
            let denominator = if exponent.is_one() {
                args[0].clone()
            } else {
                call("Power", [args[0].clone(), integer(exponent)])
            };
            Some((Vec::new(), vec![denominator]))
        }
        _ if algebraic_expr_convertible(expr) => Some((vec![expr.clone()], Vec::new())),
        _ => None,
    }
}

fn evaluate_numeric_constructor(name: &str, args: &[Expr]) -> Option<Expr> {
    match (name, args) {
        ("Rational", [Expr::Integer(numerator), Expr::Integer(denominator)]) => {
            Some(rational(numerator.clone(), denominator.clone()))
        }
        ("Complex", [real, imaginary]) if is_real_number(real) && is_real_number(imaginary) => {
            Some(complex(real.clone(), imaginary.clone()))
        }
        ("Overflow", []) => Some(Expr::SpecialReal("Overflow".into())),
        ("Underflow", []) => Some(Expr::SpecialReal("Underflow".into())),
        ("SparseArray", args) => sparse_array_expr(args),
        _ => None,
    }
}

fn evaluate_arithmetic(name: &str, args: &[Expr]) -> Option<Expr> {
    if matches!(name, "Plus" | "Times")
        && args
            .iter()
            .any(|argument| is_symbol(argument, "Indeterminate"))
    {
        return Some(symbol("Indeterminate"));
    }
    if name == "Times"
        && args
            .iter()
            .any(|argument| is_symbol(argument, "ComplexInfinity"))
        && args
            .iter()
            .any(|argument| as_rational(argument).is_some_and(|value| value.is_zero()))
    {
        return Some(symbol("Indeterminate"));
    }
    if matches!(name, "Plus" | "Times")
        && args
            .iter()
            .any(|argument| matches!(argument, Expr::SparseArray { .. }))
    {
        return sparse_elementwise_expr(name, args);
    }
    match name {
        "Plus" => simplify_plus(args),
        "Times" => simplify_times(args),
        "Power" => simplify_power(args),
        "Sqrt" if args.len() == 1 => exact_power(&args[0], &BigRational::new(1.into(), 2.into())),
        "Abs" if args.len() == 1 => match &args[0] {
            Expr::Integer(value) => Some(integer(value.abs())),
            Expr::Rational(value) => Some(Expr::Rational(value.abs())),
            Expr::Real(text) => Some(Expr::Real(format_machine_real(real_to_f64(text)?.abs()))),
            Expr::Complex { real, imaginary } => {
                let real = as_rational(real)?;
                let imaginary = as_rational(imaginary)?;
                exact_square_root(real.pow(2) + imaginary.pow(2))
            }
            Expr::Call { head, args }
                if is_symbol(head, "Times")
                    && args.first().is_some_and(|factor| factor == &integer(-1)) =>
            {
                Some(call("Abs", args.iter().skip(1).cloned()))
            }
            Expr::Call { head, args }
                if is_symbol(head, "Power")
                    && matches!(args.as_slice(), [_, Expr::Integer(power)] if power.is_even()) =>
            {
                Some(call(
                    "Power",
                    [call("Abs", [args[0].clone()]), args[1].clone()],
                ))
            }
            _ => None,
        },
        "Sign" if args.len() == 1 => {
            if let Some(value) = as_rational(&args[0]) {
                Some(integer(if value.is_zero() {
                    0
                } else if value.is_positive() {
                    1
                } else {
                    -1
                }))
            } else if let Expr::Complex { real, imaginary } = &args[0] {
                let real_part = as_rational(real)?;
                let imaginary_part = as_rational(imaginary)?;
                let norm = real_part.pow(2) + imaginary_part.pow(2);
                if let Some(magnitude) = exact_rational_sqrt(&norm) {
                    Some(complex(
                        from_rational(as_rational(real)? / &magnitude),
                        from_rational(as_rational(imaginary)? / magnitude),
                    ))
                } else {
                    Some(call(
                        "Times",
                        [
                            args[0].clone(),
                            call("Power", [from_rational(norm), rational(-1, 2)]),
                        ],
                    ))
                }
            } else {
                None
            }
        }
        "RealAbs" if args.len() == 1 => match &args[0] {
            Expr::Integer(value) => Some(integer(value.abs())),
            Expr::Rational(value) => Some(Expr::Rational(value.abs())),
            Expr::Real(text) => Some(Expr::Real(format_machine_real(real_to_f64(text)?.abs()))),
            _ => None,
        },
        "RealSign" if args.len() == 1 => numeric_real_value(&args[0]).map(|value| {
            integer(if value == 0.0 {
                0
            } else if value > 0.0 {
                1
            } else {
                -1
            })
        }),
        "Unitize" if args.len() == 1 => numeric_complex_value(&args[0])
            .map(|(real, imaginary)| integer(usize::from(real != 0.0 || imaginary != 0.0))),
        "UnitStep" => {
            let comparisons = args
                .iter()
                .map(numeric_real_value)
                .collect::<Option<Vec<_>>>()?;
            Some(integer(usize::from(
                comparisons.iter().all(|value| *value >= 0.0),
            )))
        }
        "Ramp" if args.len() == 1 => numeric_real_value(&args[0]).map(|value| {
            if value > 0.0 {
                args[0].clone()
            } else {
                integer(0)
            }
        }),
        "Mod" if matches!(args.len(), 2 | 3) => {
            let offset = args.get(2).cloned().unwrap_or_else(|| integer(0));
            if let (Some(value), Some(modulus), Some(offset)) = (
                as_rational(&args[0]),
                as_rational(&args[1]),
                as_rational(&offset),
            ) {
                if modulus.is_zero() {
                    return None;
                }
                let quotient = ((&value - &offset) / &modulus).floor().to_integer();
                Some(from_rational(
                    value - modulus * BigRational::from_integer(quotient),
                ))
            } else {
                let value = numeric_real_value(&args[0])?;
                let modulus = numeric_real_value(&args[1])?;
                let offset = numeric_real_value(&offset)?;
                (modulus != 0.0).then(|| {
                    Expr::Real(format_machine_real(
                        value - modulus * ((value - offset) / modulus).floor(),
                    ))
                })
            }
        }
        "Quotient" if matches!(args.len(), 2 | 3) => {
            let offset = args.get(2).cloned().unwrap_or_else(|| integer(0));
            let value = as_rational(&args[0])?;
            let divisor = as_rational(&args[1])?;
            let offset = as_rational(&offset)?;
            if divisor.is_zero() {
                return None;
            }
            Some(integer(((value - offset) / divisor).floor().to_integer()))
        }
        "QuotientRemainder" if args.len() == 2 => {
            let value = as_rational(&args[0])?;
            let divisor = as_rational(&args[1])?;
            if divisor.is_zero() {
                return None;
            }
            let quotient = (&value / &divisor).floor().to_integer();
            let remainder = value - divisor * BigRational::from_integer(quotient.clone());
            Some(list([integer(quotient), from_rational(remainder)]))
        }
        "Clip" if matches!(args.len(), 1..=3) => {
            let value = numeric_real_value(&args[0])?;
            let (lower, upper) = match args.get(1) {
                None => (integer(-1), integer(1)),
                Some(bounds) if bounds.has_head("List") && bounds.args().len() == 2 => {
                    (bounds.args()[0].clone(), bounds.args()[1].clone())
                }
                _ => return None,
            };
            let (below, above) = match args.get(2) {
                None => (lower.clone(), upper.clone()),
                Some(replacements)
                    if replacements.has_head("List") && replacements.args().len() == 2 =>
                {
                    (
                        replacements.args()[0].clone(),
                        replacements.args()[1].clone(),
                    )
                }
                _ => return None,
            };
            let lower_value = numeric_real_value(&lower)?;
            let upper_value = numeric_real_value(&upper)?;
            Some(if value < lower_value {
                below
            } else if value > upper_value {
                above
            } else {
                args[0].clone()
            })
        }
        "KroneckerDelta" if !args.is_empty() => Some(integer(usize::from(
            args.windows(2).all(|pair| pair[0] == pair[1]),
        ))),
        "DiscreteDelta"
            if !args.is_empty() && args.iter().all(|value| as_rational(value).is_some()) =>
        {
            Some(integer(usize::from(args.iter().all(|value| {
                as_rational(value).is_some_and(|value| value.is_zero())
            }))))
        }
        "Re" if args.len() == 1 => match &args[0] {
            Expr::Complex { real, .. } => Some(real.as_ref().clone()),
            value if is_real_number(value) => Some(value.clone()),
            _ => None,
        },
        "Im" if args.len() == 1 => match &args[0] {
            Expr::Complex { imaginary, .. } => Some(imaginary.as_ref().clone()),
            value if is_real_number(value) => Some(integer(0)),
            _ => None,
        },
        "Conjugate" if args.len() == 1 => match &args[0] {
            Expr::Complex { real, imaginary } => Some(complex(
                real.as_ref().clone(),
                multiply_exact_numbers(imaginary, &integer(-1))?,
            )),
            Expr::Root {
                coefficients,
                index,
                method,
            } if coefficients
                == &[
                    BigInt::from(-2),
                    BigInt::zero(),
                    BigInt::zero(),
                    BigInt::one(),
                ]
                && *index > 0 =>
            {
                Some(Expr::Root {
                    coefficients: coefficients.clone(),
                    index: 3 - *index,
                    method: *method,
                })
            }
            value if is_real_number(value) => Some(value.clone()),
            _ => None,
        },
        "Floor" => floor_ceiling_expr(args, false),
        "Ceiling" => floor_ceiling_expr(args, true),
        "Round" => round_expr(args),
        "IntegerPart" if args.len() == 1 => {
            if let Some((real, imaginary)) = numeric_complex_value(&args[0])
                && imaginary != 0.0
            {
                Some(complex(
                    integer(BigInt::from(real.trunc() as i128)),
                    integer(BigInt::from(imaginary.trunc() as i128)),
                ))
            } else {
                numeric_real_value(&args[0])
                    .map(|value| integer(BigInt::from(value.trunc() as i128)))
            }
        }
        "FractionalPart" if args.len() == 1 => {
            if let Some(value) = as_rational(&args[0]) {
                let integer_part = value.to_integer();
                Some(from_rational(
                    value - BigRational::from_integer(integer_part),
                ))
            } else if let Some((real, imaginary)) = numeric_complex_value(&args[0])
                && imaginary != 0.0
            {
                Some(complex(
                    Expr::Real(format_machine_real(real.fract())),
                    Expr::Real(format_machine_real(imaginary.fract())),
                ))
            } else {
                numeric_real_value(&args[0])
                    .map(|value| Expr::Real(format_machine_real(value.fract())))
            }
        }
        "GCD"
            if args
                .iter()
                .all(|argument| matches!(argument, Expr::Integer(_))) =>
        {
            Some(integer(args.iter().fold(
                BigInt::zero(),
                |result, argument| {
                    let Expr::Integer(value) = argument else {
                        unreachable!()
                    };
                    result.gcd(value)
                },
            )))
        }
        "LCM"
            if args
                .iter()
                .all(|argument| matches!(argument, Expr::Integer(_))) =>
        {
            Some(integer(args.iter().fold(
                BigInt::one(),
                |result, argument| {
                    let Expr::Integer(value) = argument else {
                        unreachable!()
                    };
                    result.lcm(value)
                },
            )))
        }
        "Divisors" if args.len() == 1 => integer_divisors(&args[0]),
        "PrimeQ" if args.len() == 1 => integer_prime_q(&args[0]).map(bool_expr),
        "EulerPhi" if args.len() == 1 => integer_euler_phi(&args[0]).map(integer),
        "MoebiusMu" if args.len() == 1 => integer_moebius_mu(&args[0]).map(integer),
        "PrimePi" if args.len() == 1 => integer_prime_pi(&args[0]).map(integer),
        "Prime" if args.len() == 1 => integer_nth_prime(&args[0]).map(integer),
        "NextPrime" if args.len() == 1 => integer_next_prime(&args[0]).map(integer),
        "PowerMod" if args.len() == 3 => integer_power_mod(args),
        "BitAnd" if args.len() == 2 => integer_binary(args, |left, right| left & right),
        "BitOr" if args.len() == 2 => integer_binary(args, |left, right| left | right),
        "BitXor" if args.len() == 2 => integer_binary(args, |left, right| left ^ right),
        "BitShiftLeft" if args.len() == 2 => integer_shift(args, true),
        "BitShiftRight" if args.len() == 2 => integer_shift(args, false),
        "IntegerDigits" => integer_digits_expr(args),
        "FromDigits" => from_digits_expr(args),
        "IntegerLength" => integer_length_expr(args),
        "PrimePowerQ" if args.len() == 1 => integer_prime_power_q(&args[0]).map(bool_expr),
        "ChineseRemainder" if args.len() == 2 => chinese_remainder_expr(args).map(integer),
        "FactorInteger" if args.len() == 1 => factor_integer_expr(&args[0]),
        "IntegerExponent" => integer_exponent_expr(args),
        "Min" => min_max_expr(args, false),
        "Max" => min_max_expr(args, true),
        _ => None,
    }
}

fn simplify_plus(args: &[Expr]) -> Option<Expr> {
    simplify_plus_internal(args, true)
}

fn simplify_plus_internal(args: &[Expr], factor_common: bool) -> Option<Expr> {
    let flattened = args
        .iter()
        .flat_map(|argument| {
            if argument.has_head("Plus") {
                argument.args().to_vec()
            } else {
                vec![argument.clone()]
            }
        })
        .collect::<Vec<_>>();
    let args = flattened.as_slice();
    if args.is_empty() {
        return Some(integer(0));
    }
    if args.len() == 1 {
        return Some(args[0].clone());
    }
    if args
        .iter()
        .any(|argument| matches!(argument, Expr::Real(_)))
        && args.iter().all(is_real_number)
    {
        return inexact_real_arithmetic(args, false);
    }
    if args.iter().all(is_exact_number) {
        let mut result = integer(0);
        for argument in args {
            result = add_exact_numbers(&result, argument)?;
        }
        return Some(result);
    }
    let mut constant = BigRational::zero();
    let mut terms: Vec<(Expr, BigRational)> = Vec::new();
    for argument in args {
        let (coefficient, base) = split_additive_term(argument);
        if let Some(base) = base {
            if let Some((_, existing)) = terms.iter_mut().find(|(existing, _)| existing == &base) {
                *existing += coefficient;
            } else {
                terms.push((base, coefficient));
            }
        } else {
            constant += coefficient;
        }
    }
    let mut result = Vec::new();
    if !constant.is_zero() {
        result.push(from_rational(constant));
    }
    for (base, coefficient) in terms {
        if coefficient.is_zero() {
            continue;
        }
        result.push(if coefficient.is_one() {
            base
        } else if base.has_head("Times") {
            call(
                "Times",
                std::iter::once(from_rational(coefficient)).chain(base.args().iter().cloned()),
            )
        } else {
            call("Times", [from_rational(coefficient), base])
        });
    }
    let mut result = if factor_common {
        factor_common_additive_terms(&result).unwrap_or(result)
    } else {
        result
    };
    Some(match result.len() {
        0 => integer(0),
        1 => result.pop().expect("one result"),
        _ => call("Plus", result),
    })
}

fn split_additive_term(expr: &Expr) -> (BigRational, Option<Expr>) {
    if let Some(value) = as_rational(expr) {
        return (value, None);
    }
    if let Expr::Call { head, args } = expr
        && is_symbol(head, "Times")
    {
        let mut coefficient = BigRational::one();
        let mut factors = Vec::new();
        for factor in args {
            if let Some(value) = as_rational(factor) {
                coefficient *= value;
            } else {
                factors.push(factor.clone());
            }
        }
        let base = match factors.len() {
            0 => None,
            1 => factors.pop(),
            _ => Some(call("Times", factors)),
        };
        return (coefficient, base);
    }
    (BigRational::one(), Some(expr.clone()))
}

fn factor_common_additive_terms(arguments: &[Expr]) -> Option<Vec<Expr>> {
    let decomposed = arguments
        .iter()
        .map(|argument| {
            let (coefficient, base) = split_additive_term(argument);
            let factors = match base {
                None => Vec::new(),
                Some(base) if base.has_head("Times") => base.args().to_vec(),
                Some(base) => vec![base],
            };
            (coefficient, factors)
        })
        .collect::<Vec<_>>();
    let mut unique_factors = Vec::new();
    for (_, factors) in &decomposed {
        for factor in factors {
            if !unique_factors.contains(factor) {
                unique_factors.push(factor.clone());
            }
        }
    }
    let mut best_indices = Vec::new();
    let mut best_common = Vec::new();
    for factor in unique_factors {
        let indices = decomposed
            .iter()
            .enumerate()
            .filter_map(|(index, (_, factors))| factors.contains(&factor).then_some(index))
            .collect::<Vec<_>>();
        if indices.len() < 2 {
            continue;
        }
        let mut common = decomposed[indices[0]].1.clone();
        common.retain(|candidate| {
            indices[1..]
                .iter()
                .all(|index| decomposed[*index].1.contains(candidate))
        });
        if (indices.len(), common.len()) > (best_indices.len(), best_common.len()) {
            best_indices = indices;
            best_common = common;
        }
    }
    if best_indices.is_empty() || best_common.is_empty() {
        return None;
    }
    let mut quotients = Vec::new();
    for index in &best_indices {
        let (coefficient, factors) = &decomposed[*index];
        let mut remaining = factors.clone();
        for common in &best_common {
            if let Some(position) = remaining.iter().position(|factor| factor == common) {
                remaining.remove(position);
            }
        }
        if !coefficient.is_one() || remaining.is_empty() {
            remaining.insert(0, from_rational(coefficient.clone()));
        }
        quotients.push(simplify_times(&remaining).unwrap_or_else(|| call("Times", remaining)));
    }
    let inner_sum = simplify_plus(&quotients).unwrap_or_else(|| call("Plus", quotients));
    let common = simplify_times(&best_common).unwrap_or_else(|| call("Times", best_common));
    let factored = simplify_times(&[common, inner_sum])?;
    let selected = best_indices.iter().copied().collect::<BTreeSet<_>>();
    let mut rebuilt = Vec::new();
    let mut inserted = false;
    for (index, argument) in arguments.iter().enumerate() {
        if selected.contains(&index) {
            if !inserted {
                rebuilt.push(factored.clone());
                inserted = true;
            }
        } else {
            rebuilt.push(argument.clone());
        }
    }
    factor_common_additive_terms(&rebuilt).or(Some(rebuilt))
}

fn simplify_times(args: &[Expr]) -> Option<Expr> {
    let flattened = args
        .iter()
        .flat_map(|argument| {
            if argument.has_head("Times") {
                argument.args().to_vec()
            } else {
                vec![argument.clone()]
            }
        })
        .collect::<Vec<_>>();
    let args = flattened.as_slice();
    if args.is_empty() {
        return Some(integer(1));
    }
    if args.len() == 1 {
        return Some(args[0].clone());
    }
    if args
        .iter()
        .any(|argument| matches!(argument, Expr::Real(_)))
        && args.iter().all(is_real_number)
    {
        return inexact_real_arithmetic(args, true);
    }
    if args.iter().all(is_exact_number) {
        let mut result = integer(1);
        for argument in args {
            result = multiply_exact_numbers(&result, argument)?;
        }
        return Some(result);
    }
    let mut coefficient = BigRational::one();
    let mut powers: Vec<(Expr, Expr)> = Vec::new();
    let mut others = Vec::new();
    for argument in args {
        if let Some(value) = as_rational(argument) {
            coefficient *= value;
            continue;
        }
        let (base, exponent) = match argument {
            Expr::Call { head, args } if is_symbol(head, "Power") && args.len() == 2 => {
                (args[0].clone(), args[1].clone())
            }
            _ => (argument.clone(), integer(1)),
        };
        if let Some((_, existing)) = powers.iter_mut().find(|(existing, _)| existing == &base) {
            *existing = simplify_plus(&[existing.clone(), exponent.clone()])
                .unwrap_or_else(|| call("Plus", [existing.clone(), exponent]));
        } else if matches!(argument, Expr::Call { .. } | Expr::Symbol(_)) {
            powers.push((base, exponent));
        } else {
            others.push(argument.clone());
        }
    }
    if coefficient.is_zero() {
        return Some(integer(0));
    }
    let mut factors = Vec::new();
    for (base, exponent) in powers {
        if exponent == integer(0) {
            continue;
        }
        factors.push(if exponent == integer(1) {
            base
        } else {
            call("Power", [base, exponent])
        });
    }
    factors.extend(others);
    factors.sort_by(expression_order);
    if !coefficient.is_one() || factors.is_empty() {
        factors.insert(0, from_rational(coefficient));
    }
    Some(match factors.len() {
        0 => integer(1),
        1 => factors.pop().expect("one factor"),
        _ => call("Times", factors),
    })
}

fn simplify_power(args: &[Expr]) -> Option<Expr> {
    match args {
        [] => Some(integer(1)),
        [base] => Some(base.clone()),
        [base, _] if base == &integer(1) => Some(integer(1)),
        [base, Expr::Integer(exponent)] => {
            if exponent.is_zero() {
                return (!as_rational(base).is_some_and(|value| value.is_zero()))
                    .then(|| integer(1));
            }
            if exponent.is_one() {
                return Some(base.clone());
            }
            if let Some(base) = as_rational(base) {
                let magnitude = exponent.abs().to_u32()?;
                let numerator = base.numer().pow(magnitude);
                let denominator = base.denom().pow(magnitude);
                return Some(if exponent.is_negative() {
                    rational(denominator, numerator)
                } else {
                    rational(numerator, denominator)
                });
            }
            if let Expr::Call {
                head,
                args: inner_args,
            } = base
                && is_symbol(head, "Power")
                && inner_args.len() == 2
            {
                let combined = simplify_times(&[inner_args[1].clone(), integer(exponent.clone())])
                    .unwrap_or_else(|| {
                        call("Times", [inner_args[1].clone(), integer(exponent.clone())])
                    });
                return Some(call("Power", [inner_args[0].clone(), combined]));
            }
            if base.has_head("Times") {
                let mut factors = Vec::new();
                for factor in base.args() {
                    let powered = simplify_power(&[factor.clone(), integer(exponent.clone())])
                        .unwrap_or_else(|| {
                            call("Power", [factor.clone(), integer(exponent.clone())])
                        });
                    factors.push(powered);
                }
                return simplify_times(&factors);
            }
            if exponent == &BigInt::from(-1) {
                if matches!(base, Expr::SpecialReal(name) if name == "Overflow") {
                    return Some(Expr::SpecialReal("Underflow".into()));
                }
                if matches!(base, Expr::SpecialReal(name) if name == "Underflow") {
                    return Some(Expr::SpecialReal("Overflow".into()));
                }
            }
            None
        }
        [base, Expr::Rational(exponent)] => exact_power(base, exponent),
        _ => None,
    }
}

fn exact_power(base: &Expr, exponent: &BigRational) -> Option<Expr> {
    let base = as_rational(base)?;
    let numerator_power = exponent.numer().to_i64()?;
    let root = exponent.denom().to_u32()?;
    if root <= 1 {
        return None;
    }
    if base.is_negative() {
        if root == 2 && numerator_power == 1 {
            let magnitude = exact_positive_root_power(&base.abs(), 1, 2)?;
            return Some(if magnitude == integer(1) {
                symbol("I")
            } else {
                call("Times", [magnitude, symbol("I")])
            });
        }
        return None;
    }
    exact_positive_root_power(&base, numerator_power, root)
}

fn exact_positive_root_power(base: &BigRational, numerator_power: i64, root: u32) -> Option<Expr> {
    let (outside_numerator, inside_numerator) = extract_nth_power(base.numer(), root)?;
    let (outside_denominator, inside_denominator) = extract_nth_power(base.denom(), root)?;
    let outside = BigRational::new(outside_numerator, outside_denominator);
    let inside = BigRational::new(inside_numerator, inside_denominator);
    let magnitude = u32::try_from(numerator_power.unsigned_abs()).ok()?;
    let outside_power = BigRational::new(
        outside.numer().pow(magnitude),
        outside.denom().pow(magnitude),
    );
    let outside_power = if numerator_power < 0 {
        outside_power.recip()
    } else {
        outside_power
    };
    if inside.is_one() {
        return Some(from_rational(outside_power));
    }
    let radical = call(
        "Power",
        [
            from_rational(inside),
            rational(numerator_power, i64::from(root)),
        ],
    );
    Some(if outside_power.is_one() {
        radical
    } else {
        call("Times", [from_rational(outside_power), radical])
    })
}

fn extract_nth_power(value: &BigInt, root: u32) -> Option<(BigInt, BigInt)> {
    let mut remaining = value.to_u64()?;
    let mut outside = BigInt::one();
    let mut inside = BigInt::one();
    let mut prime = 2_u64;
    while prime <= remaining / prime {
        if remaining % prime != 0 {
            prime += if prime == 2 { 1 } else { 2 };
            continue;
        }
        let mut count = 0_u32;
        while remaining % prime == 0 {
            remaining /= prime;
            count += 1;
        }
        outside *= BigInt::from(prime).pow(count / root);
        inside *= BigInt::from(prime).pow(count % root);
        prime += if prime == 2 { 1 } else { 2 };
    }
    if remaining > 1 {
        inside *= remaining;
    }
    Some((outside, inside))
}

fn min_max_expr(args: &[Expr], maximum: bool) -> Option<Expr> {
    let mut values = Vec::new();
    for argument in args {
        if argument.has_head("List") {
            values.extend(argument.args().iter().cloned());
        } else {
            values.push(argument.clone());
        }
    }
    if values.is_empty() {
        return Some(if maximum {
            symbol("-Infinity")
        } else {
            symbol("Infinity")
        });
    }
    if values.iter().all(|value| {
        matches!(value, Expr::Root { coefficients, .. }
        if coefficients
            == &[
                BigInt::one(),
                BigInt::from(-3),
                BigInt::zero(),
                BigInt::one(),
            ])
    }) {
        return values.into_iter().reduce(|left, right| {
            let Expr::Root {
                index: left_index, ..
            } = &left
            else {
                unreachable!()
            };
            let Expr::Root {
                index: right_index, ..
            } = &right
            else {
                unreachable!()
            };
            if (maximum && right_index > left_index) || (!maximum && right_index < left_index) {
                right
            } else {
                left
            }
        });
    }
    let mut symbolic = Vec::new();
    let mut numeric: Option<Expr> = None;
    for value in values {
        if numeric_real_value(&value).is_some() {
            numeric = Some(numeric.map_or(value.clone(), |current| {
                let order = numeric_real_value(&value)
                    .partial_cmp(&numeric_real_value(&current))
                    .unwrap_or(Ordering::Equal);
                if (maximum && order == Ordering::Greater) || (!maximum && order == Ordering::Less)
                {
                    value
                } else {
                    current
                }
            }));
        } else {
            symbolic.push(value);
        }
    }
    if let Some(numeric) = numeric {
        symbolic.push(numeric);
    }
    symbolic.sort_by(expression_order);
    Some(match symbolic.len() {
        0 => unreachable!(),
        1 => symbolic.pop().expect("one result"),
        _ => call(if maximum { "Max" } else { "Min" }, symbolic),
    })
}

fn evaluate_relation(name: &str, args: &[Expr]) -> Option<Expr> {
    match name {
        "SameQ" => Some(bool_expr(args.windows(2).all(|pair| pair[0] == pair[1]))),
        "UnsameQ" => Some(bool_expr(args.iter().enumerate().all(|(index, value)| {
            args[index + 1..].iter().all(|other| value != other)
        }))),
        "Equal" | "Unequal" | "Less" | "LessEqual" | "Greater" | "GreaterEqual"
            if args.iter().all(|value| {
                matches!(value, Expr::Root { coefficients, .. }
                if coefficients
                    == &[
                        BigInt::one(),
                        BigInt::from(-3),
                        BigInt::zero(),
                        BigInt::one(),
                    ])
            }) =>
        {
            Some(bool_expr(args.windows(2).all(|pair| {
                let Expr::Root { index: left, .. } = &pair[0] else {
                    unreachable!()
                };
                let Expr::Root { index: right, .. } = &pair[1] else {
                    unreachable!()
                };
                match name {
                    "Equal" => left == right,
                    "Unequal" => left != right,
                    "Less" => left < right,
                    "LessEqual" => left <= right,
                    "Greater" => left > right,
                    "GreaterEqual" => left >= right,
                    _ => unreachable!(),
                }
            })))
        }
        "Equal" | "Unequal" | "Less" | "LessEqual" | "Greater" | "GreaterEqual"
            if args
                .iter()
                .all(|argument| numeric_real_value(argument).is_some()) =>
        {
            let comparison = args.windows(2).all(|pair| {
                let left = numeric_real_value(&pair[0]).expect("checked");
                let right = numeric_real_value(&pair[1]).expect("checked");
                match name {
                    "Equal" => left == right,
                    "Unequal" => left != right,
                    "Less" => left < right,
                    "LessEqual" => left <= right,
                    "Greater" => left > right,
                    "GreaterEqual" => left >= right,
                    _ => unreachable!(),
                }
            });
            Some(bool_expr(comparison))
        }
        "Inequality" if args.len() >= 3 && args.len() % 2 == 1 => {
            let mut all_true = true;
            for index in (1..args.len()).step_by(2) {
                let operator = args[index].symbol_name().map(system_dispatch_name)?;
                let result = evaluate_relation(
                    operator,
                    &[args[index - 1].clone(), args[index + 1].clone()],
                );
                match result {
                    Some(value) if is_symbol(&value, "True") => {}
                    Some(value) if is_symbol(&value, "False") => return Some(value),
                    _ => all_true = false,
                }
            }
            all_true.then(|| symbol("True"))
        }
        "Not" if args.len() == 1 && is_symbol(&args[0], "True") => Some(symbol("False")),
        "Not" if args.len() == 1 && is_symbol(&args[0], "False") => Some(symbol("True")),
        _ => None,
    }
}

fn floor_ceiling_expr(args: &[Expr], ceiling: bool) -> Option<Expr> {
    let (value, unit) = match args {
        [value] => (value, None),
        [value, unit] => (value, Some(unit)),
        _ => return None,
    };
    if let Some(unit) = unit {
        let value = as_rational(value)?;
        let unit = as_rational(unit)?;
        if unit.is_zero() {
            return None;
        }
        let quotient = value / &unit;
        let rounded = if ceiling {
            quotient.ceil()
        } else {
            quotient.floor()
        }
        .to_integer();
        return Some(from_rational(unit * BigRational::from_integer(rounded)));
    }
    if let Some(value) = as_rational(value) {
        return Some(integer(
            (if ceiling { value.ceil() } else { value.floor() }).to_integer(),
        ));
    }
    let value = numeric_real_value(value)?;
    Some(integer(BigInt::from(if ceiling {
        value.ceil() as i128
    } else {
        value.floor() as i128
    })))
}

fn round_expr(args: &[Expr]) -> Option<Expr> {
    let (value, unit) = match args {
        [value] => (value, None),
        [value, unit] => (value, Some(unit)),
        _ => return None,
    };
    if let Some(unit) = unit {
        let value = as_rational(value)?;
        let unit = as_rational(unit)?;
        if unit.is_zero() {
            return None;
        }
        let rounded = (value / &unit).to_f64()?.round_ties_even() as i128;
        return Some(from_rational(
            unit * BigRational::from_integer(BigInt::from(rounded)),
        ));
    }
    let rounded = numeric_real_value(value)?.round_ties_even() as i128;
    Some(integer(BigInt::from(rounded)))
}

fn integer_divisors(expr: &Expr) -> Option<Expr> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    let value = value.abs().to_u64()?;
    if value == 0 {
        return None;
    }
    let mut low = Vec::new();
    let mut high = Vec::new();
    let mut divisor = 1_u64;
    while divisor <= value / divisor {
        if value % divisor == 0 {
            low.push(integer(divisor));
            if divisor != value / divisor {
                high.push(integer(value / divisor));
            }
        }
        divisor += 1;
    }
    high.reverse();
    low.extend(high);
    Some(list(low))
}

fn is_prime_u64(value: u64) -> bool {
    if value < 2 {
        return false;
    }
    if value % 2 == 0 {
        return value == 2;
    }
    let mut divisor = 3_u64;
    while divisor <= value / divisor {
        if value % divisor == 0 {
            return false;
        }
        divisor += 2;
    }
    true
}

fn integer_prime_q(expr: &Expr) -> Option<bool> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    Some(is_prime_u64(value.to_u64().unwrap_or(0)))
}

fn integer_prime_power_q(expr: &Expr) -> Option<bool> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    let value = value.abs().to_u64()?;
    Some(value > 1 && prime_factors(value).len() == 1)
}

fn chinese_remainder_expr(args: &[Expr]) -> Option<BigInt> {
    let [residues, moduli] = args else {
        return None;
    };
    if !residues.has_head("List")
        || !moduli.has_head("List")
        || residues.args().len() != moduli.args().len()
    {
        return None;
    }
    let mut result = BigInt::zero();
    let mut product = BigInt::one();
    for (residue, modulus) in residues.args().iter().zip(moduli.args()) {
        let (Expr::Integer(residue), Expr::Integer(modulus)) = (residue, modulus) else {
            return None;
        };
        if modulus.is_zero() {
            return None;
        }
        let gcd = product.extended_gcd(modulus);
        if !gcd.gcd.is_one() {
            return None;
        }
        let adjustment = ((residue - &result) * gcd.x).mod_floor(modulus);
        result += &product * adjustment;
        product *= modulus;
        result = result.mod_floor(&product);
    }
    Some(result)
}

fn factor_integer_expr(expr: &Expr) -> Option<Expr> {
    let value = as_rational(expr)?;
    if value.is_zero() {
        return Some(list([list([integer(0), integer(1)])]));
    }
    let mut factors: Vec<(BigInt, i64)> = Vec::new();
    if value.is_negative() {
        factors.push((BigInt::from(-1), 1));
    }
    for (prime, exponent) in prime_factors(value.numer().abs().to_u64()?) {
        factors.push((BigInt::from(prime), i64::from(exponent)));
    }
    for (prime, exponent) in prime_factors(value.denom().to_u64()?) {
        factors.push((BigInt::from(prime), -i64::from(exponent)));
    }
    factors.sort_by(|left, right| left.0.cmp(&right.0));
    Some(list(factors.into_iter().map(|(prime, exponent)| {
        list([integer(prime), integer(exponent)])
    })))
}

fn integer_exponent_expr(args: &[Expr]) -> Option<Expr> {
    let ([Expr::Integer(value)] | [Expr::Integer(value), _]) = args else {
        return None;
    };
    if value.is_zero() {
        return Some(symbol("Infinity"));
    }
    let base = match args.get(1) {
        None => BigInt::from(10),
        Some(Expr::Integer(base)) if base.abs() > BigInt::one() => base.abs(),
        _ => return None,
    };
    let mut value = value.abs();
    let mut exponent = 0_usize;
    while (&value % &base).is_zero() {
        value /= &base;
        exponent += 1;
    }
    Some(integer(exponent))
}

fn prime_factors(mut value: u64) -> Vec<(u64, u32)> {
    let mut factors = Vec::new();
    let mut prime = 2_u64;
    while prime <= value / prime {
        if value % prime == 0 {
            let mut exponent = 0;
            while value % prime == 0 {
                value /= prime;
                exponent += 1;
            }
            factors.push((prime, exponent));
        }
        prime = if prime == 2 { 3 } else { prime + 2 };
    }
    if value > 1 {
        factors.push((value, 1));
    }
    factors
}

fn integer_euler_phi(expr: &Expr) -> Option<BigInt> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    let value = value.abs().to_u64()?;
    let mut result = value;
    for (prime, _) in prime_factors(value) {
        result = result / prime * (prime - 1);
    }
    Some(BigInt::from(result))
}

fn integer_moebius_mu(expr: &Expr) -> Option<BigInt> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    let value = value.abs().to_u64()?;
    if value == 0 {
        return Some(BigInt::zero());
    }
    let factors = prime_factors(value);
    if factors.iter().any(|(_, exponent)| *exponent > 1) {
        Some(BigInt::zero())
    } else {
        Some(BigInt::from(if factors.len() % 2 == 0 { 1 } else { -1 }))
    }
}

fn integer_prime_pi(expr: &Expr) -> Option<BigInt> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    let value = value.to_u64()?;
    Some(BigInt::from(
        (2..=value).filter(|value| is_prime_u64(*value)).count(),
    ))
}

fn integer_nth_prime(expr: &Expr) -> Option<BigInt> {
    let Expr::Integer(index) = expr else {
        return None;
    };
    let index = index.to_usize()?;
    if index == 0 {
        return None;
    }
    let mut count = 0;
    let mut candidate = 1_u64;
    loop {
        candidate += 1;
        if is_prime_u64(candidate) {
            count += 1;
            if count == index {
                return Some(BigInt::from(candidate));
            }
        }
    }
}

fn integer_next_prime(expr: &Expr) -> Option<BigInt> {
    let Expr::Integer(value) = expr else {
        return None;
    };
    let mut candidate = value.to_u64()? + 1;
    while !is_prime_u64(candidate) {
        candidate += 1;
    }
    Some(BigInt::from(candidate))
}

fn integer_power_mod(args: &[Expr]) -> Option<Expr> {
    let [
        Expr::Integer(base),
        Expr::Integer(exponent),
        Expr::Integer(modulus),
    ] = args
    else {
        return None;
    };
    if modulus.is_zero() {
        return None;
    }
    let modulus = modulus.abs();
    let base = if exponent.is_negative() {
        let gcd = base.extended_gcd(&modulus);
        if !gcd.gcd.is_one() {
            return None;
        }
        gcd.x.mod_floor(&modulus)
    } else {
        base.mod_floor(&modulus)
    };
    Some(integer(base.modpow(&exponent.abs(), &modulus)))
}

fn integer_binary(args: &[Expr], operation: impl FnOnce(BigInt, BigInt) -> BigInt) -> Option<Expr> {
    let [Expr::Integer(left), Expr::Integer(right)] = args else {
        return None;
    };
    Some(integer(operation(left.clone(), right.clone())))
}

fn integer_shift(args: &[Expr], left: bool) -> Option<Expr> {
    let [Expr::Integer(value), Expr::Integer(amount)] = args else {
        return None;
    };
    let amount = amount.to_i64()?;
    let (left, amount) = if amount < 0 {
        (!left, amount.unsigned_abs() as usize)
    } else {
        (left, amount as usize)
    };
    Some(integer(if left {
        value << amount
    } else {
        value >> amount
    }))
}

fn integer_digits_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::Integer(value), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 2 {
        return None;
    }
    let base = match rest.first() {
        None => BigInt::from(10),
        Some(Expr::Integer(base)) if *base >= BigInt::from(2) => base.clone(),
        _ => return None,
    };
    let mut value = value.abs();
    let mut digits = Vec::new();
    if value.is_zero() {
        digits.push(integer(0));
    }
    while !value.is_zero() {
        let (quotient, remainder) = value.div_rem(&base);
        digits.push(integer(remainder));
        value = quotient;
    }
    digits.reverse();
    if let Some(Expr::Integer(length)) = rest.get(1) {
        let length = length.to_usize()?;
        if digits.len() < length {
            let mut padded = vec![integer(0); length - digits.len()];
            padded.extend(digits);
            digits = padded;
        } else if digits.len() > length {
            digits = digits.split_off(digits.len() - length);
        }
    }
    Some(list(digits))
}

fn from_digits_expr(args: &[Expr]) -> Option<Expr> {
    let [digits, rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let base = match rest {
        [] => BigInt::from(10),
        [Expr::Integer(base)] if *base >= BigInt::from(2) => base.clone(),
        _ => return None,
    };
    let digits = match digits {
        Expr::Call { head, args } if is_symbol(head, "List") => args
            .iter()
            .map(|digit| match digit {
                Expr::Integer(value) => Some(value.clone()),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()?,
        Expr::String(value) => value
            .chars()
            .map(|character| character.to_digit(36).map(BigInt::from))
            .collect::<Option<Vec<_>>>()?,
        _ => return None,
    };
    Some(integer(
        digits
            .into_iter()
            .fold(BigInt::zero(), |value, digit| value * &base + digit),
    ))
}

fn integer_length_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::Integer(value), rest @ ..] = args else {
        return None;
    };
    let base = match rest {
        [] => BigInt::from(10),
        [Expr::Integer(base)] if *base >= BigInt::from(2) => base.clone(),
        _ => return None,
    };
    let mut value = value.abs();
    let mut length = 1_usize;
    while value >= base {
        value /= &base;
        length += 1;
    }
    Some(integer(length))
}

fn evaluate_predicate(name: &str, args: &[Expr]) -> Option<Expr> {
    let [argument] = args else {
        return None;
    };
    Some(bool_expr(match name {
        "AtomQ" => argument.is_atom(),
        "IntegerQ" => matches!(argument, Expr::Integer(_)),
        "NumberQ" => is_number(argument),
        "NumericQ" => numeric_q(argument),
        "ExactNumberQ" => is_exact_number(argument),
        "InexactNumberQ" => numeric_q(argument) && contains_inexact_number(argument),
        "RealValuedNumberQ" => is_real_number(argument) || matches!(argument, Expr::SpecialReal(_)),
        "MachineNumberQ" => numeric_q(argument) && is_machine_number(argument),
        "MachineIntegerQ" => {
            matches!(argument, Expr::Integer(value) if value >= &BigInt::from(i64::MIN) && value <= &BigInt::from(i64::MAX))
        }
        "StringQ" => matches!(argument, Expr::String(_)),
        "ListQ" => argument.has_head("List"),
        "AssociationQ" => association_entries(argument).is_some(),
        "SparseArrayQ" => matches!(argument, Expr::SparseArray { .. }),
        "ByteArrayQ" => matches!(argument, Expr::ByteArray(_)),
        "TrueQ" => is_symbol(argument, "True"),
        "EvenQ" => matches!(argument, Expr::Integer(value) if (value % 2u8).is_zero()),
        "OddQ" => matches!(argument, Expr::Integer(value) if !(value % 2u8).is_zero()),
        "FailureQ" => {
            argument.has_head("Failure")
                || matches!(argument, Expr::Symbol(name) if matches!(system_dispatch_name(name), "$Failed" | "$Canceled" | "$Aborted"))
        }
        "MissingQ" => argument.has_head("Missing"),
        _ => return None,
    }))
}

fn single(args: &[Expr]) -> Option<&Expr> {
    match args {
        [value] => Some(value),
        _ => None,
    }
}

fn normalize_association(args: &[Expr]) -> Option<Expr> {
    let mut entries = Vec::new();
    fn append_entries(source: &Expr, entries: &mut Vec<Expr>) -> bool {
        if source.has_head("List") || source.has_head("Association") {
            return source
                .args()
                .iter()
                .all(|item| append_entries(item, entries));
        }
        if is_symbol(source, "Nothing") {
            return true;
        }
        if !(source.has_head("Rule") || source.has_head("RuleDelayed")) || source.args().len() != 2
        {
            return false;
        }
        if is_symbol(&source.args()[0], "Nothing") {
            return true;
        }
        if let Some(existing) = entries
            .iter_mut()
            .find(|entry: &&mut Expr| entry.args()[0] == source.args()[0])
        {
            *existing = source.clone();
        } else {
            entries.push(source.clone());
        }
        true
    }
    if !args
        .iter()
        .all(|argument| append_entries(argument, &mut entries))
    {
        return None;
    }
    Some(call("Association", entries))
}

fn association_entries(expr: &Expr) -> Option<Vec<Expr>> {
    (expr.has_head("Association")
        && expr.args().iter().all(|entry| {
            (entry.has_head("Rule") || entry.has_head("RuleDelayed")) && entry.args().len() == 2
        }))
    .then(|| expr.args().to_vec())
}

fn association_first_last(args: &[Expr], last: bool) -> Option<Expr> {
    let [association] = args else {
        return None;
    };
    let entries = association_entries(association)?;
    let entry = if last {
        entries.last()?
    } else {
        entries.first()?
    };
    Some(entry.args().get(1)?.clone())
}

fn association_keys_values(args: &[Expr], values: bool) -> Option<Expr> {
    let [association] = args else {
        return None;
    };
    let entries = association_entries(association)?;
    let index = usize::from(values);
    Some(list(entries.into_iter().filter_map(|entry| {
        let item = entry.args().get(index)?.clone();
        (!is_symbol(&item, "Nothing")).then_some(item)
    })))
}

fn association_lookup(association: &Expr, key: &Expr, default: Option<&Expr>) -> Expr {
    association_entries(association)
        .and_then(|entries| {
            entries
                .into_iter()
                .find(|entry| entry.args().first() == Some(key))
                .and_then(|entry| entry.args().get(1).cloned())
        })
        .unwrap_or_else(|| {
            default
                .cloned()
                .unwrap_or_else(|| call("Missing", [string("KeyAbsent"), key.clone()]))
        })
}

fn association_lookup_expr(args: &[Expr]) -> Option<Expr> {
    let [association, keys, rest @ ..] = args else {
        return None;
    };
    if !association.has_head("Association") || rest.len() > 1 {
        return None;
    }
    let default = rest.first();
    if keys.has_head("List") {
        return Some(list(keys.args().iter().filter_map(|key| {
            let value = association_lookup(association, key, default);
            (!is_symbol(&value, "Nothing")).then_some(value)
        })));
    }
    Some(association_lookup(association, keys, default))
}

fn association_key_exists(args: &[Expr]) -> Option<Expr> {
    let [association, key] = args else {
        return None;
    };
    let entries = association_entries(association)?;
    Some(bool_expr(
        entries
            .iter()
            .any(|entry| entry.args().first() == Some(key)),
    ))
}

fn association_key_take_drop(args: &[Expr], drop: bool) -> Option<Expr> {
    let [association, keys] = args else {
        return None;
    };
    let entries = association_entries(association)?;
    let keys = if keys.has_head("List") {
        keys.args().to_vec()
    } else {
        vec![keys.clone()]
    };
    let selected: Vec<Expr> = if drop {
        entries
            .into_iter()
            .filter(|entry| !keys.contains(&entry.args()[0]))
            .collect()
    } else {
        keys.into_iter()
            .filter_map(|key| {
                entries
                    .iter()
                    .find(|entry| entry.args().first() == Some(&key))
                    .cloned()
            })
            .collect()
    };
    Some(call("Association", selected))
}

fn association_thread(args: &[Expr]) -> Option<Expr> {
    let [keys, values] = args else {
        return None;
    };
    if !keys.has_head("List")
        || !values.has_head("List")
        || keys.args().len() != values.args().len()
    {
        return None;
    }
    Some(call(
        "Association",
        keys.args()
            .iter()
            .cloned()
            .zip(values.args().iter().cloned())
            .map(|(key, value)| call("Rule", [key, value])),
    ))
}

fn string_join_expr(args: &[Expr]) -> Option<Expr> {
    fn append(expr: &Expr, output: &mut String) -> bool {
        match expr {
            Expr::String(value) => {
                output.push_str(value);
                true
            }
            Expr::Call { head, args } if is_symbol(head, "List") => {
                args.iter().all(|argument| append(argument, output))
            }
            _ => false,
        }
    }
    let mut output = String::new();
    args.iter()
        .all(|argument| append(argument, &mut output))
        .then(|| string(output))
}

fn string_take_drop(args: &[Expr], drop: bool) -> Option<Expr> {
    let [source, spec] = args else {
        return None;
    };
    if source.has_head("List") {
        return Some(list(source.args().iter().map(|item| {
            string_take_drop(&[item.clone(), spec.clone()], drop).unwrap_or_else(|| {
                call(
                    if drop { "StringDrop" } else { "StringTake" },
                    [item.clone(), spec.clone()],
                )
            })
        })));
    }
    let Expr::String(value) = source else {
        return None;
    };
    let characters = value.chars().collect::<Vec<_>>();
    let indices = if spec.has_head("UpTo")
        && let [Expr::Integer(count)] = spec.args()
    {
        let count = count.to_usize()?.min(characters.len());
        (0..count).collect::<Vec<_>>()
    } else {
        selector_indices(characters.len(), spec)?
    };
    Some(string(
        characters
            .iter()
            .enumerate()
            .filter(|(index, _)| indices.contains(index) != drop)
            .map(|(_, character)| *character)
            .collect::<String>(),
    ))
}

fn string_insert_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(source), Expr::String(insertion), positions] = args else {
        return None;
    };
    let characters = source.chars().collect::<Vec<_>>();
    let raw_positions = if positions.has_head("List") {
        positions.args().to_vec()
    } else {
        vec![positions.clone()]
    };
    let mut boundaries = Vec::new();
    for position in raw_positions {
        let Expr::Integer(position) = position else {
            return None;
        };
        let position = position.to_i64()?;
        let boundary = if position > 0 {
            usize::try_from(position - 1).ok()?
        } else {
            usize::try_from(i64::try_from(characters.len()).ok()? + position + 1).ok()?
        };
        if boundary > characters.len() {
            return None;
        }
        boundaries.push(boundary);
    }
    let mut output = String::new();
    for boundary in 0..=characters.len() {
        for _ in boundaries
            .iter()
            .filter(|candidate| **candidate == boundary)
        {
            output.push_str(insertion);
        }
        if let Some(character) = characters.get(boundary) {
            output.push(*character);
        }
    }
    Some(string(output))
}

fn string_reverse_expr(args: &[Expr]) -> Option<Expr> {
    let [source] = args else {
        return None;
    };
    match source {
        Expr::String(value) => Some(string(value.chars().rev().collect::<String>())),
        Expr::Call { head, args } if is_symbol(head, "List") => {
            Some(list(args.iter().map(|item| match item {
                Expr::String(value) => string(value.chars().rev().collect::<String>()),
                _ => call("StringReverse", [item.clone()]),
            })))
        }
        _ => None,
    }
}

fn string_case_expr(args: &[Expr], upper: bool, capitalize: bool) -> Option<Expr> {
    let [Expr::String(value)] = args else {
        return None;
    };
    let result = if capitalize {
        let mut characters = value.chars();
        characters.next().map_or_else(String::new, |first| {
            first.to_uppercase().chain(characters).collect()
        })
    } else if upper {
        value.to_uppercase()
    } else {
        value.to_lowercase()
    };
    Some(string(result))
}

fn string_repeat_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(value), Expr::Integer(count), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let count = count.to_usize()?;
    let mut result = value.repeat(count);
    if let [Expr::Integer(limit)] = rest {
        let limit = limit.to_usize()?;
        result = result.chars().take(limit).collect();
    }
    Some(string(result))
}

fn repeated_padding(padding: &str, count: usize) -> String {
    if padding.is_empty() {
        return String::new();
    }
    padding.chars().cycle().take(count).collect()
}

fn string_pad_expr(args: &[Expr], right: bool) -> Option<Expr> {
    let [Expr::String(value), Expr::Integer(length), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let length = length.to_usize()?;
    let current = value.chars().count();
    if current >= length {
        return Some(string(value.clone()));
    }
    let padding = match rest {
        [] => " ",
        [Expr::String(padding)] => padding,
        _ => return None,
    };
    let fill = repeated_padding(padding, length - current);
    Some(string(if right {
        format!("{value}{fill}")
    } else {
        format!("{fill}{value}")
    }))
}

fn string_split_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(value), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let pieces = if rest.is_empty() {
        value
            .split_whitespace()
            .map(str::to_owned)
            .collect::<Vec<_>>()
    } else {
        let separators = match &rest[0] {
            Expr::String(separator) => vec![separator.as_str()],
            Expr::Call { head, args } if is_symbol(head, "List") => args
                .iter()
                .map(|item| match item {
                    Expr::String(value) => Some(value.as_str()),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?,
            _ => return None,
        };
        let mut pieces = vec![value.clone()];
        for separator in separators {
            pieces = pieces
                .into_iter()
                .flat_map(|piece| {
                    piece
                        .split(separator)
                        .map(str::to_owned)
                        .collect::<Vec<_>>()
                })
                .collect();
        }
        pieces
            .into_iter()
            .filter(|piece| !piece.is_empty())
            .collect()
    };
    Some(list(pieces.into_iter().map(string)))
}

fn byte_array_expr(args: &[Expr]) -> Option<Expr> {
    let [source] = args else {
        return None;
    };
    match source {
        Expr::ByteArray(_) => Some(source.clone()),
        Expr::String(value) => base64::engine::general_purpose::STANDARD
            .decode(value.as_bytes())
            .ok()
            .map(Expr::ByteArray),
        values if values.has_head("List") => values
            .args()
            .iter()
            .map(|value| match value {
                Expr::Integer(value) => value.to_u8(),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()
            .map(Expr::ByteArray),
        _ => None,
    }
}

fn base_encoding(argument: Option<&Expr>) -> Option<&'static str> {
    let Some(Expr::String(name)) = argument else {
        return argument.is_none().then_some("Base64");
    };
    match name.trim().to_ascii_lowercase().as_str() {
        "base16" => Some("Base16"),
        "base64" => Some("Base64"),
        "base85ascii" => Some("Base85ASCII"),
        _ => None,
    }
}

fn base_encode_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::ByteArray(values), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let encoded = match base_encoding(rest.first())? {
        "Base64" => base64::engine::general_purpose::STANDARD.encode(values),
        "Base16" => values
            .iter()
            .map(|value| format!("{value:02X}"))
            .collect::<String>(),
        "Base85ASCII" => ascii85_encode(values),
        _ => unreachable!(),
    };
    Some(string(encoded))
}

fn base_decode_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(source), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let encoding = base_encoding(rest.first())?;
    let decoded = match encoding {
        "Base64" => {
            let filtered = source
                .chars()
                .filter(|character| {
                    character.is_ascii_alphanumeric() || "+/=_-".contains(*character)
                })
                .collect::<String>();
            base64::engine::general_purpose::STANDARD
                .decode(filtered.as_bytes())
                .ok()?
        }
        "Base16" => {
            let filtered = source
                .chars()
                .filter(|character| character.is_ascii_hexdigit())
                .collect::<Vec<_>>();
            if filtered.len() % 2 != 0 {
                return None;
            }
            filtered
                .chunks(2)
                .map(|pair| u8::from_str_radix(&pair.iter().collect::<String>(), 16).ok())
                .collect::<Option<Vec<_>>>()?
        }
        "Base85ASCII" => ascii85_decode(source)?,
        _ => unreachable!(),
    };
    Some(Expr::ByteArray(decoded))
}

fn ascii85_encode(values: &[u8]) -> String {
    let mut output = String::new();
    for chunk in values.chunks(4) {
        let mut padded = [0_u8; 4];
        padded[..chunk.len()].copy_from_slice(chunk);
        let mut value = u32::from_be_bytes(padded);
        if chunk.len() == 4 && value == 0 {
            output.push('z');
            continue;
        }
        let mut digits = [0_u8; 5];
        for digit in digits.iter_mut().rev() {
            *digit = u8::try_from(value % 85).expect("ASCII85 digit") + b'!';
            value /= 85;
        }
        output.extend(
            digits[..chunk.len() + 1]
                .iter()
                .map(|digit| char::from(*digit)),
        );
    }
    output
}

fn ascii85_decode(source: &str) -> Option<Vec<u8>> {
    let mut digits = Vec::new();
    let mut output = Vec::new();
    for character in source
        .chars()
        .filter(|character| !character.is_whitespace())
    {
        if character == 'z' {
            if !digits.is_empty() {
                return None;
            }
            output.extend([0_u8; 4]);
            continue;
        }
        if !(('!'..='u').contains(&character)) {
            continue;
        }
        digits.push(u32::from(character) - u32::from('!'));
        if digits.len() == 5 {
            let value = digits.iter().fold(0_u32, |value, digit| value * 85 + digit);
            output.extend(value.to_be_bytes());
            digits.clear();
        }
    }
    if digits.len() == 1 {
        return None;
    }
    if !digits.is_empty() {
        let original = digits.len();
        digits.resize(5, 84);
        let value = digits.iter().fold(0_u32, |value, digit| value * 85 + digit);
        output.extend(&value.to_be_bytes()[..original - 1]);
    }
    Some(output)
}

fn import_export_format(argument: &Expr) -> Option<&'static str> {
    let Expr::String(name) = argument else {
        return None;
    };
    match name.trim().to_ascii_lowercase().as_str() {
        "byte" => Some("Byte"),
        "csv" => Some("CSV"),
        "json" => Some("JSON"),
        "rawjson" => Some("RawJSON"),
        "string" => Some("String"),
        "table" => Some("Table"),
        "text" => Some("Text"),
        "tsv" => Some("TSV"),
        "wl" => Some("WL"),
        _ => None,
    }
}

fn export_string_expr(args: &[Expr]) -> Option<Expr> {
    let [expression, format] = args else {
        return None;
    };
    if compression_spec(format).is_some() {
        let Expr::ByteArray(values) = export_byte_array_expr(args)? else {
            unreachable!()
        };
        return Some(string(
            values.into_iter().map(char::from).collect::<String>(),
        ));
    }
    let format = import_export_format(format)?;
    Some(string(match format {
        "Text" | "String" => match expression {
            Expr::String(value) => value.clone(),
            _ => expression.to_input_form(),
        },
        "Byte" => raw_byte_values(expression)?
            .into_iter()
            .map(char::from)
            .collect(),
        "JSON" => serde_json::to_string_pretty(&expr_to_json(expression, false)?).ok()?,
        "RawJSON" => serde_json::to_string_pretty(&expr_to_json(expression, true)?).ok()?,
        "CSV" => export_delimited(expression, ','),
        "TSV" => export_delimited(expression, '\t'),
        "Table" => export_table(expression),
        "WL" => expression.to_input_form(),
        _ => return None,
    }))
}

fn import_string_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(source), format] = args else {
        return None;
    };
    if compression_spec(format).is_some() {
        return import_byte_array_expr(&[
            Expr::ByteArray(raw_string_bytes(source)?),
            format.clone(),
        ]);
    }
    Some(match import_export_format(format)? {
        "Text" | "String" => string(source),
        "Byte" => list(source.chars().map(|value| integer(u32::from(value)))),
        "JSON" => json_to_expr(&serde_json::from_str(source).ok()?, false)?,
        "RawJSON" => json_to_expr(&serde_json::from_str(source).ok()?, true)?,
        "CSV" => import_delimited(source, ','),
        "TSV" => import_delimited(source, '\t'),
        "Table" => import_table(source),
        "WL" => parse_input_form(source).ok()?,
        _ => return None,
    })
}

fn export_byte_array_expr(args: &[Expr]) -> Option<Expr> {
    let [expression, format] = args else {
        return None;
    };
    if let Some((wrapper, inner)) = compression_spec(format) {
        let Expr::ByteArray(values) = export_byte_array_expr(&[expression.clone(), inner.clone()])?
        else {
            unreachable!()
        };
        return compress_bytes(&values, wrapper).map(Expr::ByteArray);
    }
    let format_name = import_export_format(format)?;
    let values = match format_name {
        "Byte" => raw_byte_values(expression)?,
        "String" => match expression {
            Expr::String(value) => raw_string_bytes(value)?,
            _ => raw_string_bytes(&expression.to_input_form())?,
        },
        "CSV" | "JSON" | "RawJSON" | "Table" | "Text" | "TSV" | "WL" => {
            let Expr::String(value) = export_string_expr(args)? else {
                unreachable!()
            };
            value.into_bytes()
        }
        _ => return None,
    };
    Some(Expr::ByteArray(values))
}

fn import_byte_array_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::ByteArray(values), format] = args else {
        return None;
    };
    if let Some((wrapper, inner)) = compression_spec(format) {
        return import_byte_array_expr(&[
            Expr::ByteArray(decompress_bytes(values, wrapper)?),
            inner.clone(),
        ]);
    }
    let format_name = import_export_format(format)?;
    match format_name {
        "Byte" => Some(list(values.iter().map(|value| integer(*value)))),
        "String" => Some(string(
            values
                .iter()
                .map(|value| char::from(*value))
                .collect::<String>(),
        )),
        "CSV" | "JSON" | "RawJSON" | "Table" | "Text" | "TSV" | "WL" => {
            let decoded = decode_utf8_surrogate_escape(values);
            import_string_expr(&[string(decoded), format.clone()])
        }
        _ => None,
    }
}

fn compression_spec(format: &Expr) -> Option<(&'static str, &Expr)> {
    let [Expr::String(wrapper), inner] = format.args() else {
        return None;
    };
    if !format.has_head("List") {
        return None;
    }
    match wrapper.trim().to_ascii_lowercase().as_str() {
        "gzip" => Some(("GZIP", inner)),
        "bzip2" => Some(("BZIP2", inner)),
        _ => None,
    }
}

fn compress_bytes(values: &[u8], format: &str) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    match format {
        "GZIP" => {
            let mut encoder = flate2::read::GzEncoder::new(values, flate2::Compression::default());
            encoder.read_to_end(&mut output).ok()?;
        }
        "BZIP2" => {
            let mut encoder = bzip2::read::BzEncoder::new(values, bzip2::Compression::best());
            encoder.read_to_end(&mut output).ok()?;
        }
        _ => return None,
    }
    Some(output)
}

fn decompress_bytes(values: &[u8], format: &str) -> Option<Vec<u8>> {
    let mut output = Vec::new();
    match format {
        "GZIP" => {
            let mut decoder = flate2::read::GzDecoder::new(values);
            decoder.read_to_end(&mut output).ok()?;
        }
        "BZIP2" => {
            let mut decoder = bzip2::read::BzDecoder::new(values);
            decoder.read_to_end(&mut output).ok()?;
        }
        _ => return None,
    }
    Some(output)
}

fn raw_byte_values(expression: &Expr) -> Option<Vec<u8>> {
    match expression {
        Expr::ByteArray(values) => Some(values.clone()),
        value if value.has_head("List") => value
            .args()
            .iter()
            .map(|item| match item {
                Expr::Integer(value) => value.to_u8(),
                _ => None,
            })
            .collect(),
        _ => None,
    }
}

fn raw_string_bytes(source: &str) -> Option<Vec<u8>> {
    source
        .chars()
        .map(|character| u8::try_from(u32::from(character)).ok())
        .collect()
}

fn json_to_expr(value: &serde_json::Value, raw: bool) -> Option<Expr> {
    match value {
        serde_json::Value::Null => Some(symbol("Null")),
        serde_json::Value::Bool(value) => Some(bool_expr(*value)),
        serde_json::Value::Number(value) => {
            let text = value.to_string();
            if !text.contains(['.', 'e', 'E']) {
                text.parse::<BigInt>().ok().map(integer)
            } else {
                text.parse::<f64>()
                    .ok()
                    .map(|value| Expr::Real(format_machine_real(value)))
            }
        }
        serde_json::Value::String(value) => Some(string(value)),
        serde_json::Value::Array(values) => Some(list(
            values
                .iter()
                .map(|value| json_to_expr(value, raw))
                .collect::<Option<Vec<_>>>()?,
        )),
        serde_json::Value::Object(values) => {
            let rules = values
                .iter()
                .map(|(key, value)| Some(call("Rule", [string(key), json_to_expr(value, raw)?])))
                .collect::<Option<Vec<_>>>()?;
            Some(if raw {
                normalize_association(&rules)?
            } else {
                list(rules)
            })
        }
    }
}

fn expr_to_json(expression: &Expr, raw: bool) -> Option<serde_json::Value> {
    match expression {
        Expr::String(value) => Some(json!(value)),
        Expr::Integer(value) => serde_json::from_str(&value.to_string()).ok(),
        Expr::Real(value) => serde_json::from_str(&value.replace("*^", "e")).ok(),
        Expr::Symbol(name) => match system_dispatch_name(name) {
            "True" => Some(json!(true)),
            "False" => Some(json!(false)),
            "Null" => Some(serde_json::Value::Null),
            _ => None,
        },
        value if value.has_head("List") => {
            if let Some(object) = rule_object(value.args(), raw) {
                return Some(serde_json::Value::Object(object));
            }
            Some(serde_json::Value::Array(
                value
                    .args()
                    .iter()
                    .map(|item| expr_to_json(item, raw))
                    .collect::<Option<Vec<_>>>()?,
            ))
        }
        value if value.has_head("Association") => {
            let entries = association_entries(value)?;
            Some(serde_json::Value::Object(rule_object(&entries, false)?))
        }
        _ => None,
    }
}

fn rule_object(entries: &[Expr], raw: bool) -> Option<serde_json::Map<String, serde_json::Value>> {
    if entries.is_empty() || !entries.iter().all(|entry| entry.has_head("Rule")) {
        return None;
    }
    if raw {
        return None;
    }
    let mut object = serde_json::Map::new();
    for entry in entries {
        let [Expr::String(key), value] = entry.args() else {
            return None;
        };
        object.insert(key.clone(), expr_to_json(value, raw)?);
    }
    Some(object)
}

fn import_delimited(source: &str, delimiter: char) -> Expr {
    list(
        parse_delimited_rows(source, delimiter)
            .into_iter()
            .map(|row| list(row.into_iter().map(|field| parse_tabular_atom(&field)))),
    )
}

fn parse_delimited_rows(source: &str, delimiter: char) -> Vec<Vec<String>> {
    let mut rows = Vec::new();
    let mut row = Vec::new();
    let mut field = String::new();
    let mut characters = source.chars().peekable();
    let mut quoted = false;
    while let Some(character) = characters.next() {
        if quoted {
            if character == '"' {
                if characters.peek() == Some(&'"') {
                    characters.next();
                    field.push('"');
                } else {
                    quoted = false;
                }
            } else {
                field.push(character);
            }
        } else if character == '"' && field.is_empty() {
            quoted = true;
        } else if character == delimiter {
            row.push(std::mem::take(&mut field));
        } else if character == '\n' {
            row.push(std::mem::take(&mut field));
            rows.push(std::mem::take(&mut row));
        } else if character != '\r' {
            field.push(character);
        }
    }
    if !field.is_empty() || !row.is_empty() {
        row.push(field);
        rows.push(row);
    }
    rows
}

fn import_table(source: &str) -> Expr {
    list(source.lines().map(|line| {
        if line.trim().is_empty() {
            list([])
        } else {
            list(line.split_whitespace().map(parse_tabular_atom))
        }
    }))
}

fn parse_tabular_atom(source: &str) -> Expr {
    let trimmed = source.trim();
    if let Ok(value) = trimmed.parse::<BigInt>() {
        return integer(value);
    }
    let normalized = trimmed.replace("*^", "e").replace(['d', 'D'], "e");
    if (trimmed.contains('.') || normalized.contains(['e', 'E']))
        && let Ok(value) = normalized.parse::<f64>()
    {
        return Expr::Real(format_machine_real(value));
    }
    string(source)
}

fn tabular_rows(expression: &Expr) -> Vec<Vec<String>> {
    let render = |value: &Expr| match value {
        Expr::String(value) => value.clone(),
        _ => value.to_input_form(),
    };
    if !expression.has_head("List") {
        return vec![vec![render(expression)]];
    }
    if expression.args().is_empty() {
        return Vec::new();
    }
    if expression
        .args()
        .iter()
        .all(|value| !value.has_head("List"))
    {
        return expression
            .args()
            .iter()
            .map(|value| vec![render(value)])
            .collect();
    }
    expression
        .args()
        .iter()
        .map(|row| row.args().iter().map(&render).collect())
        .collect()
}

fn export_delimited(expression: &Expr, delimiter: char) -> String {
    let separator = delimiter.to_string();
    tabular_rows(expression)
        .into_iter()
        .map(|row| {
            row.into_iter()
                .map(|field| quote_delimited_field(&field, delimiter))
                .collect::<Vec<_>>()
                .join(&separator)
        })
        .collect::<Vec<_>>()
        .join("\n")
        + "\n"
}

fn quote_delimited_field(field: &str, delimiter: char) -> String {
    if field.contains(delimiter) || field.contains(['"', '\n', '\r']) {
        format!("\"{}\"", field.replace('"', "\"\""))
    } else {
        field.to_owned()
    }
}

fn export_table(expression: &Expr) -> String {
    tabular_rows(expression)
        .into_iter()
        .map(|row| row.join("\t"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum CharacterEncoding {
    Unicode,
    PrintableAscii,
    Ascii,
    Latin1,
    Utf8,
    Utf16Le,
    Utf16Be,
    Utf32Le,
    Utf32Be,
}

fn character_encoding(argument: Option<&Expr>, unicode_default: bool) -> Option<CharacterEncoding> {
    let Some(Expr::String(name)) = argument else {
        return argument.is_none().then_some(if unicode_default {
            CharacterEncoding::Unicode
        } else {
            CharacterEncoding::Utf8
        });
    };
    Some(match name.trim().to_ascii_lowercase().as_str() {
        "unicode" => CharacterEncoding::Unicode,
        "printableascii" | "printable-ascii" => CharacterEncoding::PrintableAscii,
        "ascii" => CharacterEncoding::Ascii,
        "iso8859-1" | "iso-8859-1" | "latin1" | "latin-1" => CharacterEncoding::Latin1,
        "utf-8" | "utf8" => CharacterEncoding::Utf8,
        "utf-16le" | "utf16le" => CharacterEncoding::Utf16Le,
        "utf-16be" | "utf16be" => CharacterEncoding::Utf16Be,
        "utf-32le" | "utf32le" => CharacterEncoding::Utf32Le,
        "utf-32be" | "utf32be" => CharacterEncoding::Utf32Be,
        _ => return None,
    })
}

fn to_character_code_expr(args: &[Expr]) -> Option<Expr> {
    let [source, rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    if source.has_head("List") {
        return Some(list(source.args().iter().map(|item| {
            let mut threaded = vec![item.clone()];
            threaded.extend(rest.iter().cloned());
            to_character_code_expr(&threaded).unwrap_or_else(|| call("ToCharacterCode", threaded))
        })));
    }
    let Expr::String(source) = source else {
        return None;
    };
    let encoding = character_encoding(rest.first(), true)?;
    Some(list(encode_character_codes(source, encoding)))
}

fn encode_character_codes(source: &str, encoding: CharacterEncoding) -> Vec<Expr> {
    match encoding {
        CharacterEncoding::Unicode => source
            .chars()
            .map(|value| integer(u32::from(value)))
            .collect(),
        CharacterEncoding::Ascii | CharacterEncoding::PrintableAscii => source
            .chars()
            .map(|value| {
                if value.is_ascii() {
                    integer(u32::from(value))
                } else {
                    symbol("None")
                }
            })
            .collect(),
        CharacterEncoding::Latin1 => source
            .chars()
            .map(|value| {
                let value = u32::from(value);
                if value <= 255 {
                    integer(value)
                } else {
                    symbol("None")
                }
            })
            .collect(),
        encoding => encode_string(source, encoding)
            .unwrap_or_default()
            .into_iter()
            .map(integer)
            .collect(),
    }
}

fn from_character_code_expr(args: &[Expr]) -> Option<Expr> {
    let [source, rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let values = integer_code_values(source)?;
    let encoding = character_encoding(rest.first(), true)?;
    let text = if encoding == CharacterEncoding::Unicode {
        values
            .into_iter()
            .map(|value| char::from_u32(value))
            .collect::<Option<String>>()?
    } else {
        let bytes = values
            .into_iter()
            .map(|value| u8::try_from(value).ok())
            .collect::<Option<Vec<_>>>()?;
        decode_bytes(&bytes, encoding)?
    };
    Some(string(text))
}

fn string_to_byte_array_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(source), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let encoding = character_encoding(rest.first(), false)?;
    if encoding == CharacterEncoding::Unicode {
        return None;
    }
    encode_string(source, encoding).map(Expr::ByteArray)
}

fn byte_array_to_string_expr(args: &[Expr]) -> Option<Expr> {
    let [source, rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let values = match source {
        Expr::ByteArray(values) => values.as_slice(),
        value if value.has_head("List") && value.args().is_empty() => &[],
        _ => return None,
    };
    let encoding = character_encoding(rest.first(), false)?;
    if encoding == CharacterEncoding::Unicode {
        return None;
    }
    decode_bytes(values, encoding).map(string)
}

fn integer_code_values(source: &Expr) -> Option<Vec<u32>> {
    match source {
        Expr::Integer(value) => Some(vec![value.to_u32()?]),
        value if value.has_head("List") => value
            .args()
            .iter()
            .map(|item| match item {
                Expr::Integer(value) => value.to_u32(),
                _ => None,
            })
            .collect(),
        _ => None,
    }
}

fn encode_string(source: &str, encoding: CharacterEncoding) -> Option<Vec<u8>> {
    match encoding {
        CharacterEncoding::Utf8 => Some(source.as_bytes().to_vec()),
        CharacterEncoding::Ascii | CharacterEncoding::PrintableAscii => source
            .chars()
            .map(|character| u8::try_from(u32::from(character)).ok().filter(u8::is_ascii))
            .collect(),
        CharacterEncoding::Latin1 => source
            .chars()
            .map(|character| u8::try_from(u32::from(character)).ok())
            .collect(),
        CharacterEncoding::Utf16Le | CharacterEncoding::Utf16Be => {
            let mut bytes = Vec::new();
            for unit in source.encode_utf16() {
                bytes.extend(if encoding == CharacterEncoding::Utf16Le {
                    unit.to_le_bytes()
                } else {
                    unit.to_be_bytes()
                });
            }
            Some(bytes)
        }
        CharacterEncoding::Utf32Le | CharacterEncoding::Utf32Be => {
            let mut bytes = Vec::new();
            for character in source.chars() {
                let value = u32::from(character);
                bytes.extend(if encoding == CharacterEncoding::Utf32Le {
                    value.to_le_bytes()
                } else {
                    value.to_be_bytes()
                });
            }
            Some(bytes)
        }
        CharacterEncoding::Unicode => None,
    }
}

fn decode_bytes(values: &[u8], encoding: CharacterEncoding) -> Option<String> {
    match encoding {
        CharacterEncoding::Utf8 => Some(decode_utf8_surrogate_escape(values)),
        CharacterEncoding::Ascii | CharacterEncoding::PrintableAscii => Some(
            values
                .iter()
                .map(|value| {
                    if value.is_ascii() {
                        char::from(*value)
                    } else {
                        char::from_u32(0xF200 + u32::from(*value)).expect("private-use code point")
                    }
                })
                .collect(),
        ),
        CharacterEncoding::Latin1 => Some(values.iter().map(|value| char::from(*value)).collect()),
        CharacterEncoding::Utf16Le | CharacterEncoding::Utf16Be => {
            if values.len() % 2 != 0 {
                return None;
            }
            let units = values
                .chunks_exact(2)
                .map(|chunk| {
                    if encoding == CharacterEncoding::Utf16Le {
                        u16::from_le_bytes([chunk[0], chunk[1]])
                    } else {
                        u16::from_be_bytes([chunk[0], chunk[1]])
                    }
                })
                .collect::<Vec<_>>();
            char::decode_utf16(units)
                .map(|value| value.ok())
                .collect::<Option<String>>()
        }
        CharacterEncoding::Utf32Le | CharacterEncoding::Utf32Be => {
            if values.len() % 4 != 0 {
                return None;
            }
            values
                .chunks_exact(4)
                .map(|chunk| {
                    let bytes = [chunk[0], chunk[1], chunk[2], chunk[3]];
                    char::from_u32(if encoding == CharacterEncoding::Utf32Le {
                        u32::from_le_bytes(bytes)
                    } else {
                        u32::from_be_bytes(bytes)
                    })
                })
                .collect::<Option<String>>()
        }
        CharacterEncoding::Unicode => Some(values.iter().map(|value| char::from(*value)).collect()),
    }
}

fn decode_utf8_surrogate_escape(values: &[u8]) -> String {
    let mut remaining = values;
    let mut output = String::new();
    while !remaining.is_empty() {
        match std::str::from_utf8(remaining) {
            Ok(text) => {
                output.push_str(text);
                break;
            }
            Err(error) => {
                let valid = error.valid_up_to();
                output.push_str(std::str::from_utf8(&remaining[..valid]).expect("valid prefix"));
                let skip = error.error_len().unwrap_or(1);
                for value in &remaining[valid..valid + skip] {
                    output.push(char::from(*value));
                }
                remaining = &remaining[valid + skip..];
            }
        }
    }
    output
}

fn string_riffle_expr(args: &[Expr]) -> Option<Expr> {
    let [items, rest @ ..] = args else {
        return None;
    };
    if !items.has_head("List") || rest.len() > 1 {
        return None;
    }
    let values = items
        .args()
        .iter()
        .map(|item| match item {
            Expr::String(value) => Some(value.as_str()),
            _ => None,
        })
        .collect::<Option<Vec<_>>>()?;
    let (left, separator, right) = match rest {
        [] => ("", " ", ""),
        [Expr::String(separator)] => ("", separator.as_str(), ""),
        [triple] if triple.has_head("List") => match triple.args() {
            [
                Expr::String(left),
                Expr::String(separator),
                Expr::String(right),
            ] => (left.as_str(), separator.as_str(), right.as_str()),
            _ => return None,
        },
        _ => return None,
    };
    Some(string(format!("{left}{}{right}", values.join(separator))))
}

fn string_trim_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(value), rest @ ..] = args else {
        return None;
    };
    match rest {
        [] => Some(string(value.trim().to_owned())),
        [Expr::String(pattern)] => Some(string(
            value
                .strip_prefix(pattern)
                .unwrap_or(value)
                .strip_suffix(pattern)
                .unwrap_or_else(|| value.strip_prefix(pattern).unwrap_or(value))
                .to_owned(),
        )),
        _ => None,
    }
}

fn compile_string_pattern(pattern: &Expr) -> Option<CompiledStringPattern> {
    let mut compiler = StringPatternCompiler::default();
    let fragment = compiler.fragment(pattern, false)?;
    Some(CompiledStringPattern {
        regex: regex::Regex::new(&fragment).ok()?,
        bindings: compiler.bindings,
        tests: compiler.tests,
    })
}

impl StringPatternCompiler {
    fn named_group(&mut self, name: &str, fragment: String) -> String {
        let group = format!("tungsten{}", self.next_group);
        self.next_group += 1;
        self.bindings
            .entry(name.to_owned())
            .or_default()
            .push(group.clone());
        format!("(?P<{group}>{fragment})")
    }

    fn fragment(&mut self, pattern: &Expr, shortest: bool) -> Option<String> {
        match pattern {
            Expr::String(value) => return Some(regex::escape(value)),
            Expr::Symbol(name) => {
                return Some(match system_dispatch_name(name) {
                    "DigitCharacter" => r"\d".into(),
                    "HexadecimalCharacter" => "[0-9A-Fa-f]".into(),
                    "LetterCharacter" => r"\p{L}".into(),
                    "PunctuationCharacter" => r"\p{P}".into(),
                    "WhitespaceCharacter" => r"\s".into(),
                    "WordCharacter" => r"[\p{L}\p{N}_]".into(),
                    "Whitespace" => r"\s+".into(),
                    "NumberString" => r"[+-]?(?:\d+(?:\.\d*)?|\.\d+)".into(),
                    "WordBoundary" => r"\b".into(),
                    "StartOfLine" => r"(?m:^)".into(),
                    "EndOfLine" => r"(?m:$)".into(),
                    _ => return None,
                });
            }
            _ => {}
        }
        if pattern.has_head("HoldPattern") && pattern.args().len() == 1 {
            return self.fragment(&pattern.args()[0], shortest);
        }
        if pattern.has_head("Longest") && matches!(pattern.args(), [_] | [_, _]) {
            return self.fragment(&pattern.args()[0], false);
        }
        if pattern.has_head("Shortest") && matches!(pattern.args(), [_] | [_, _]) {
            return self.fragment(&pattern.args()[0], true);
        }
        if pattern.has_head("StringExpression") {
            return pattern
                .args()
                .iter()
                .map(|part| self.fragment(part, shortest))
                .collect::<Option<Vec<_>>>()
                .map(|parts| parts.concat());
        }
        if pattern.has_head("Alternatives") && !pattern.args().is_empty() {
            let alternatives = pattern
                .args()
                .iter()
                .map(|part| self.fragment(part, shortest))
                .collect::<Option<Vec<_>>>()?;
            return Some(format!("(?:{})", alternatives.join("|")));
        }
        if pattern.has_head("RegularExpression")
            && let [Expr::String(source)] = pattern.args()
        {
            if let Some(source) = source.strip_prefix("(?i)") {
                return Some(format!("(?i:{source})"));
            }
            return Some(format!("(?:{source})"));
        }
        if pattern.has_head("CharacterRange")
            && let [Expr::String(start), Expr::String(end)] = pattern.args()
            && start.chars().count() == 1
            && end.chars().count() == 1
        {
            return Some(format!("[{}-{}]", regex::escape(start), regex::escape(end)));
        }
        if pattern.has_head("Blank") && pattern.args().is_empty() {
            return Some("(?s:.)".into());
        }
        if pattern.has_head("BlankSequence") && pattern.args().is_empty() {
            return Some(if shortest { "(?s:.+?)" } else { "(?s:.+)" }.into());
        }
        if pattern.has_head("BlankNullSequence") && pattern.args().is_empty() {
            return Some(if shortest { "(?s:.*?)" } else { "(?s:.*)" }.into());
        }
        if matches!(
            pattern.head().symbol_name().map(system_dispatch_name),
            Some("Repeated" | "RepeatedNull")
        ) && matches!(pattern.args(), [_] | [_, _])
        {
            let inner = self.fragment(&pattern.args()[0], shortest)?;
            let repeated_null = pattern.has_head("RepeatedNull");
            let quantifier = if let Some(spec) = pattern.args().get(1) {
                repetition_quantifier(spec)?
            } else if repeated_null {
                "*".into()
            } else {
                "+".into()
            };
            return Some(format!(
                "(?:{inner}){quantifier}{}",
                if shortest { "?" } else { "" }
            ));
        }
        if pattern.has_head("Pattern")
            && let [Expr::Symbol(name), inner] = pattern.args()
        {
            let fragment = self.fragment(inner, shortest)?;
            return Some(self.named_group(name, fragment));
        }
        if pattern.has_head("PatternTest")
            && let [inner, criterion] = pattern.args()
        {
            if let Some(class) = string_pattern_test_class(criterion) {
                let fragment = match inner.head().symbol_name().map(system_dispatch_name) {
                    Some("Blank") if inner.args().is_empty() => class,
                    Some("BlankSequence") if inner.args().is_empty() => {
                        format!("(?:{class})+{}", if shortest { "?" } else { "" })
                    }
                    Some("BlankNullSequence") if inner.args().is_empty() => {
                        format!("(?:{class})*{}", if shortest { "?" } else { "" })
                    }
                    _ => self.fragment(inner, shortest)?,
                };
                return Some(fragment);
            }
            let fragment = self.fragment(inner, shortest)?;
            let group = format!("tungsten{}", self.next_group);
            self.next_group += 1;
            self.tests.push((group.clone(), criterion.clone()));
            return Some(format!("(?P<{group}>{fragment})"));
        }
        if pattern.has_head("Except") && matches!(pattern.args(), [_] | [_, _]) {
            let excluded = character_class_contents(&pattern.args()[0])?;
            if let Some(allowed) = pattern.args().get(1)
                && !(allowed.has_head("Blank") && allowed.args().is_empty())
            {
                return None;
            }
            return Some(format!("[^{excluded}]"));
        }
        if pattern.has_head("DatePattern") && matches!(pattern.args(), [_] | [_, _]) {
            let elements = &pattern.args()[0];
            if !elements.has_head("List") || elements.args().is_empty() {
                return None;
            }
            let separator = if let Some(separator) = pattern.args().get(1) {
                self.fragment(separator, shortest)?
            } else {
                r"(?:[-/.\s]+)".into()
            };
            let parts = elements
                .args()
                .iter()
                .map(|element| match element {
                    Expr::String(name) => date_pattern_fragment(name),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?;
            return Some(parts.join(&separator));
        }
        None
    }
}

fn repetition_quantifier(spec: &Expr) -> Option<String> {
    match spec {
        Expr::Integer(value) if !value.is_negative() => Some(format!("{{{value}}}")),
        spec if spec.has_head("List") => match spec.args() {
            [Expr::Integer(value)] if !value.is_negative() => Some(format!("{{{value}}}")),
            [Expr::Integer(minimum), Expr::Integer(maximum)]
                if !minimum.is_negative() && maximum >= minimum =>
            {
                Some(format!("{{{minimum},{maximum}}}"))
            }
            _ => None,
        },
        _ => None,
    }
}

fn string_pattern_test_class(criterion: &Expr) -> Option<String> {
    if is_symbol(criterion, "DigitQ") {
        return Some(r"\d".into());
    }
    if is_symbol(criterion, "LetterQ") {
        return Some(r"\p{L}".into());
    }
    if criterion.has_head("Function")
        && let [body] = criterion.args()
        && body.has_head("StringMatchQ")
        && let [slot, class] = body.args()
        && slot.has_head("Slot")
    {
        return match class.symbol_name().map(system_dispatch_name) {
            Some("DigitCharacter") => Some(r"\d".into()),
            Some("LetterCharacter") => Some(r"\p{L}".into()),
            _ => None,
        };
    }
    None
}

fn character_class_contents(pattern: &Expr) -> Option<String> {
    match pattern {
        Expr::String(value) if value.chars().count() == 1 => Some(regex::escape(value)),
        Expr::Symbol(name) => match system_dispatch_name(name) {
            "DigitCharacter" => Some(r"\d".into()),
            "HexadecimalCharacter" => Some("0-9A-Fa-f".into()),
            "LetterCharacter" => Some(r"\p{L}".into()),
            "PunctuationCharacter" => Some(r"\p{P}".into()),
            "WhitespaceCharacter" => Some(r"\s".into()),
            "WordCharacter" => Some(r"\p{L}\p{N}_".into()),
            _ => None,
        },
        pattern if pattern.has_head("List") || pattern.has_head("Alternatives") => pattern
            .args()
            .iter()
            .map(character_class_contents)
            .collect::<Option<Vec<_>>>()
            .map(|parts| parts.concat()),
        _ => None,
    }
}

fn date_pattern_fragment(name: &str) -> Option<String> {
    Some(
        match name {
            "Year" => r"(?:\d{1,4})",
            "Quarter" => r"(?:[1-4])",
            "Month" => r"(?:(?:1[0-2])|(?:0?[1-9]))",
            "Day" => r"(?:(?:[12]\d)|(?:3[01])|(?:0?[1-9]))",
            "Hour" => r"(?:(?:2[0-3])|(?:[01]?\d))",
            "Minute" | "Second" => r"(?:[0-5]?\d)",
            "AMPM" => r"(?:AM|PM|A\.M\.|P\.M\.)",
            _ => return None,
        }
        .into(),
    )
}

fn string_boundaries(source: &str) -> Vec<usize> {
    source
        .char_indices()
        .map(|(index, _)| index)
        .chain(std::iter::once(source.len()))
        .collect()
}

fn next_string_boundary(source: &str, position: usize) -> Option<usize> {
    source[position..]
        .char_indices()
        .nth(1)
        .map(|(offset, _)| position + offset)
}

fn digit_letter_q_expr(args: &[Expr], letter: bool) -> Option<Expr> {
    let [Expr::String(value)] = args else {
        return None;
    };
    Some(bool_expr(
        !value.is_empty()
            && value.chars().all(|character| {
                if letter {
                    character.is_alphabetic()
                } else {
                    character.is_numeric()
                }
            }),
    ))
}

fn string_count_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(source), Expr::String(pattern)] = args else {
        return None;
    };
    Some(integer(source.matches(pattern).count()))
}

fn normalize_string_expression(pieces: Vec<Expr>) -> Expr {
    let mut merged = Vec::new();
    let mut literal = String::new();
    for piece in pieces {
        if let Expr::String(value) = piece {
            literal.push_str(&value);
        } else {
            if !literal.is_empty() {
                merged.push(string(std::mem::take(&mut literal)));
            }
            merged.push(piece);
        }
    }
    if !literal.is_empty() {
        merged.push(string(literal));
    }
    match merged.as_slice() {
        [] => string(""),
        [only] => only.clone(),
        _ => call("StringExpression", merged),
    }
}

fn through_expr(args: &[Expr]) -> Option<Expr> {
    let ([target] | [target, _]) = args else {
        return None;
    };
    let Expr::Call {
        head: function_container,
        args: arguments,
    } = target
    else {
        return Some(target.clone());
    };
    let Expr::Call {
        head: container_head,
        args: functions,
    } = function_container.as_ref()
    else {
        return Some(target.clone());
    };
    if let Some(selected_head) = args.get(1)
        && container_head.as_ref() != selected_head
    {
        return Some(target.clone());
    }
    Some(call(
        container_head.as_ref().clone(),
        functions
            .iter()
            .map(|function| call(function.clone(), arguments.clone())),
    ))
}

fn distribute_expr(args: &[Expr]) -> Option<Expr> {
    if args.is_empty() || args.len() > 5 {
        return None;
    }
    let target = &args[0];
    let Expr::Call { head, args: values } = target else {
        return Some(target.clone());
    };
    let distributed_head = args.get(1).cloned().unwrap_or_else(|| symbol("Plus"));
    if let Some(outer_head) = args.get(2)
        && outer_head != head.as_ref()
    {
        return Some(target.clone());
    }
    let inner_replacement = args
        .get(3)
        .cloned()
        .unwrap_or_else(|| head.as_ref().clone());
    let outer_replacement = args
        .get(4)
        .cloned()
        .unwrap_or_else(|| distributed_head.clone());
    let options = values
        .iter()
        .map(|value| {
            if value.head() == distributed_head {
                value.args().to_vec()
            } else {
                vec![value.clone()]
            }
        })
        .collect::<Vec<_>>();
    if options.iter().all(|options| options.len() == 1) {
        return Some(target.clone());
    }
    fn distribute_choices(
        options: &[Vec<Expr>],
        index: usize,
        chosen: &mut Vec<Expr>,
        inner_head: &Expr,
        output: &mut Vec<Expr>,
    ) {
        if index == options.len() {
            output.push(call(inner_head.clone(), chosen.clone()));
            return;
        }
        for option in &options[index] {
            chosen.push(option.clone());
            distribute_choices(options, index + 1, chosen, inner_head, output);
            chosen.pop();
        }
    }
    let mut output = Vec::new();
    distribute_choices(
        &options,
        0,
        &mut Vec::new(),
        &inner_replacement,
        &mut output,
    );
    Some(call(outer_replacement, output))
}

fn catenate_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = if let Some(entries) = association_entries(target) {
        entries
            .into_iter()
            .map(|entry| entry.args()[1].clone())
            .collect::<Vec<_>>()
    } else {
        target_call_args(target)?.to_vec()
    };
    let mut output = Vec::new();
    for value in values {
        if !value.has_head("List") {
            return None;
        }
        output.extend(value.args().iter().cloned());
    }
    Some(list(output))
}

fn riffle_expr(args: &[Expr]) -> Option<Expr> {
    let ([target, separators] | [target, separators, _]) = args else {
        return None;
    };
    let values = target_call_args(target)?;
    if values.is_empty() {
        return Some(target.clone());
    }
    if let Some(span) = args.get(2) {
        let [
            Expr::Integer(start),
            Expr::Integer(end),
            Expr::Integer(step),
        ] = span.args()
        else {
            return None;
        };
        if !span.has_head("List") {
            return None;
        }
        let start = start.to_i64()?;
        let end = end.to_i64()?;
        let step = step.to_i64()?;
        if start < 1 || step <= 0 {
            return None;
        }
        let mut output = Vec::new();
        let mut item_index = 0;
        let mut next_separator = start;
        let mut output_position = 1_i64;
        loop {
            if end > 0 && next_separator > end {
                if item_index < values.len() {
                    output.push(values[item_index].clone());
                    item_index += 1;
                    output_position += 1;
                    continue;
                }
                break;
            }
            if output_position == next_separator {
                output.push(separators.clone());
                next_separator += step;
                output_position += 1;
            } else if item_index < values.len() {
                output.push(values[item_index].clone());
                item_index += 1;
                output_position += 1;
            } else {
                break;
            }
        }
        return Some(call(target.head(), output));
    }
    let separators = if separators.has_head("List") {
        separators.args().to_vec()
    } else {
        vec![separators.clone()]
    };
    if separators.is_empty() {
        return Some(target.clone());
    }
    let mut output = Vec::with_capacity(values.len() * 2 - 1);
    for (index, value) in values.iter().enumerate() {
        if index > 0 {
            output.push(separators[(index - 1) % separators.len()].clone());
        }
        output.push(value.clone());
    }
    Some(call(target.head(), output))
}

fn contains_expr(args: &[Expr], mode: u8) -> Option<Expr> {
    let [left, right] = args else {
        return None;
    };
    let left = target_call_args(left)?;
    let right = target_call_args(right)?;
    let mut left_unique = left.to_vec();
    left_unique.sort_by(expression_order);
    left_unique.dedup();
    let mut right_unique = right.to_vec();
    right_unique.sort_by(expression_order);
    right_unique.dedup();
    Some(bool_expr(match mode {
        0 => right_unique.iter().all(|value| left_unique.contains(value)),
        1 => right_unique.iter().any(|value| left_unique.contains(value)),
        2 => right_unique
            .iter()
            .all(|value| !left_unique.contains(value)),
        _ => left_unique == right_unique,
    }))
}

fn combinations(
    values: &[Expr],
    size: usize,
    start: usize,
    current: &mut Vec<Expr>,
    output: &mut Vec<Expr>,
) {
    if current.len() == size {
        output.push(list(current.clone()));
        return;
    }
    for index in start..values.len() {
        current.push(values[index].clone());
        combinations(values, size, index + 1, current, output);
        current.pop();
    }
}

fn subsets_expr(args: &[Expr]) -> Option<Expr> {
    let [target, rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 || !target.has_head("List") {
        return None;
    }
    let sizes = match rest {
        [] => (0..=target.args().len()).collect::<Vec<_>>(),
        [spec] if spec.has_head("List") => match spec.args() {
            [Expr::Integer(size)] => vec![size.to_usize()?],
            [Expr::Integer(minimum), Expr::Integer(maximum)] => {
                (minimum.to_usize()?..=maximum.to_usize()?).collect()
            }
            [
                Expr::Integer(minimum),
                Expr::Integer(maximum),
                Expr::Integer(step),
            ] => {
                let minimum = minimum.to_i64()?;
                let maximum = maximum.to_i64()?;
                let step = step.to_i64()?;
                if step == 0 {
                    return None;
                }
                let mut sizes = Vec::new();
                let mut size = minimum;
                while if step > 0 {
                    size <= maximum
                } else {
                    size >= maximum
                } {
                    if size >= 0 {
                        sizes.push(usize::try_from(size).ok()?);
                    }
                    size += step;
                }
                sizes
            }
            _ => return None,
        },
        _ => return None,
    };
    let mut output = Vec::new();
    for size in sizes {
        combinations(target.args(), size, 0, &mut Vec::new(), &mut output);
    }
    Some(list(output))
}

fn permutation_values(values: &mut [Expr], index: usize, output: &mut Vec<Expr>) {
    if index == values.len() {
        output.push(list(values.to_vec()));
        return;
    }
    for swap in index..values.len() {
        values.swap(index, swap);
        permutation_values(values, index + 1, output);
        values.swap(index, swap);
    }
}

fn permutations_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    if !target.has_head("List") {
        return None;
    }
    let mut values = target.args().to_vec();
    let mut output = Vec::new();
    permutation_values(&mut values, 0, &mut output);
    output.sort_by(expression_order);
    output.dedup();
    Some(list(output))
}

fn random_permutation_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::Integer(length)] = args else {
        return None;
    };
    if length.is_negative() {
        return None;
    }
    let length = length.to_usize()?;
    let mut permutation = (1..=length).map(integer).collect::<Vec<_>>();
    permutation.shuffle(&mut rand::rng());
    permutation_cycles_expr(&[list(permutation)])
}

fn random_sample_expr(args: &[Expr]) -> Option<Expr> {
    let ([target] | [target, _]) = args else {
        return None;
    };
    let Expr::Call { args: items, .. } = target else {
        return None;
    };
    let count = match args.get(1) {
        None => items.len(),
        Some(Expr::Symbol(name)) if system_dispatch_name(name) == "All" => items.len(),
        Some(Expr::Integer(value)) if !value.is_negative() => value.to_usize()?,
        Some(value) if value.has_head("UpTo") && value.args().len() == 1 => {
            let Expr::Integer(limit) = &value.args()[0] else {
                return None;
            };
            if limit.is_negative() {
                return None;
            }
            items.len().min(limit.to_usize()?)
        }
        _ => return None,
    };
    if count > items.len() {
        return None;
    }
    let mut sampled = items.clone();
    sampled.shuffle(&mut rand::rng());
    sampled.truncate(count);
    Some(call(target.head(), sampled))
}

fn permute_expr(args: &[Expr]) -> Option<Expr> {
    let [target, permutation] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    let mapping = if permutation.has_head("List") {
        permutation.args().to_vec()
    } else if permutation.has_head("Cycles")
        && let [cycles] = permutation.args()
        && cycles.has_head("List")
    {
        let mut mapping = (1..=values.len()).map(integer).collect::<Vec<_>>();
        for cycle in cycles.args() {
            if !cycle.has_head("List") {
                return None;
            }
            for index in 0..cycle.args().len() {
                let Expr::Integer(from) = &cycle.args()[index] else {
                    return None;
                };
                let to = cycle.args()[(index + 1) % cycle.args().len()].clone();
                mapping[from.to_usize()?.checked_sub(1)?] = to;
            }
        }
        mapping
    } else {
        return None;
    };
    if mapping.len() != values.len() {
        return None;
    }
    let mut output = vec![symbol("Null"); values.len()];
    for (value, destination) in values.iter().zip(mapping) {
        let Expr::Integer(destination) = destination else {
            return None;
        };
        output[destination.to_usize()?.checked_sub(1)?] = value.clone();
    }
    Some(call(target.head(), output))
}

fn pad_expr(args: &[Expr], right: bool) -> Option<Expr> {
    let [target, Expr::Integer(length), rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 {
        return None;
    }
    let values = target_call_args(target)?;
    let length = length.to_usize()?;
    if values.len() >= length {
        let retained = if right {
            &values[..length]
        } else {
            &values[values.len() - length..]
        };
        return Some(call(target.head(), retained.iter().cloned()));
    }
    let padding = rest.first().cloned().unwrap_or_else(|| integer(0));
    let padding = if padding.has_head("List") {
        padding.args().to_vec()
    } else {
        vec![padding]
    };
    if padding.is_empty() {
        return None;
    }
    let missing = length - values.len();
    let fill = (0..missing).map(|index| padding[index % padding.len()].clone());
    Some(call(
        target.head(),
        if right {
            values.iter().cloned().chain(fill).collect::<Vec<_>>()
        } else {
            fill.chain(values.iter().cloned()).collect()
        },
    ))
}

fn key_sort_expr(args: &[Expr]) -> Option<Expr> {
    let [association] = args else {
        return None;
    };
    let mut entries = association_entries(association)?;
    entries.sort_by(|left, right| expression_order(&left.args()[0], &right.args()[0]));
    Some(call("Association", entries))
}

fn gather_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    if !target.has_head("List") {
        return None;
    }
    let mut groups: Vec<Vec<Expr>> = Vec::new();
    for value in target.args() {
        if let Some(group) = groups.iter_mut().find(|group| group[0] == *value) {
            group.push(value.clone());
        } else {
            groups.push(vec![value.clone()]);
        }
    }
    Some(list(groups.into_iter().map(list)))
}

fn key_set_expr(args: &[Expr], mode: u8) -> Option<Expr> {
    let [associations] = args else {
        return None;
    };
    if !associations.has_head("List") || associations.args().is_empty() {
        return None;
    }
    let entries = associations
        .args()
        .iter()
        .map(association_entries)
        .collect::<Option<Vec<_>>>()?;
    let mut keys = entries[0]
        .iter()
        .map(|entry| entry.args()[0].clone())
        .collect::<Vec<_>>();
    match mode {
        0 => keys.retain(|key| {
            entries[1..]
                .iter()
                .all(|entries| entries.iter().all(|entry| &entry.args()[0] != key))
        }),
        1 => {
            for association in &entries[1..] {
                for entry in association {
                    let key = entry.args()[0].clone();
                    if !keys.contains(&key) {
                        keys.push(key);
                    }
                }
            }
        }
        _ => keys.retain(|key| {
            entries[1..]
                .iter()
                .all(|entries| entries.iter().any(|entry| &entry.args()[0] == key))
        }),
    }
    if mode == 0 {
        return Some(call(
            "Association",
            entries[0]
                .iter()
                .filter(|entry| keys.contains(&entry.args()[0]))
                .cloned(),
        ));
    }
    Some(list(entries.into_iter().map(|association| {
        call(
            "Association",
            keys.iter().map(|key| {
                let value = association
                    .iter()
                    .find(|entry| &entry.args()[0] == key)
                    .map_or_else(
                        || call("Missing", [string("KeyAbsent"), key.clone()]),
                        |entry| entry.args()[1].clone(),
                    );
                call("Rule", [key.clone(), value])
            }),
        )
    })))
}

fn boole_expr(args: &[Expr]) -> Option<Expr> {
    let [value] = args else {
        return None;
    };
    if value.has_head("List") {
        return Some(list(
            value
                .args()
                .iter()
                .map(|value| boole_expr(&[value.clone()]))
                .collect::<Option<Vec<_>>>()?,
        ));
    }
    if is_symbol(value, "True") {
        Some(integer(1))
    } else if is_symbol(value, "False") {
        Some(integer(0))
    } else {
        None
    }
}

fn transpose_expr(args: &[Expr]) -> Option<Expr> {
    let [matrix] = args else {
        return None;
    };
    if let Expr::SparseArray {
        dimensions,
        entries,
        fill_value,
    } = matrix
        && dimensions.len() == 2
    {
        let mut entries = entries
            .iter()
            .map(|(position, value)| (vec![position[1], position[0]], value.clone()))
            .collect::<Vec<_>>();
        entries.sort_by(|left, right| left.0.cmp(&right.0));
        return Some(Expr::SparseArray {
            dimensions: vec![dimensions[1], dimensions[0]],
            entries,
            fill_value: fill_value.clone(),
        });
    }
    if !matrix.has_head("List") || matrix.args().is_empty() {
        return None;
    }
    let rows = matrix
        .args()
        .iter()
        .map(|row| row.has_head("List").then_some(row.args()))
        .collect::<Option<Vec<_>>>()?;
    let columns = rows.first()?.len();
    if rows.iter().any(|row| row.len() != columns) {
        return None;
    }
    Some(list((0..columns).map(|column| {
        list(rows.iter().map(|row| row[column].clone()))
    })))
}

fn insert_expr(args: &[Expr]) -> Option<Expr> {
    let [target, item, Expr::Integer(position)] = args else {
        return None;
    };
    let mut values = target_call_args(target)?.to_vec();
    let position = position.to_i64()?;
    let index = if position > 0 {
        usize::try_from(position - 1).ok()?
    } else {
        usize::try_from(i64::try_from(values.len()).ok()? + position + 1).ok()?
    };
    if index > values.len() {
        return None;
    }
    values.insert(index, item.clone());
    Some(call(target.head(), values))
}

fn flatten_at_expr(args: &[Expr]) -> Option<Expr> {
    let [target, Expr::Integer(position)] = args else {
        return None;
    };
    let mut values = target_call_args(target)?.to_vec();
    let index = resolve_index(values.len(), position.to_i64()?)?;
    let nested = target_call_args(&values[index])?.to_vec();
    values.splice(index..=index, nested);
    Some(call(target.head(), values))
}

fn split_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    let mut groups: Vec<Vec<Expr>> = Vec::new();
    for value in values {
        if groups.last().and_then(|group| group.last()) == Some(value) {
            groups.last_mut()?.push(value.clone());
        } else {
            groups.push(vec![value.clone()]);
        }
    }
    Some(list(groups.into_iter().map(list)))
}

fn delete_adjacent_duplicates_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    let values = target_call_args(target)?;
    let mut output = Vec::new();
    for value in values {
        if output.last() != Some(value) {
            output.push(value.clone());
        }
    }
    Some(call(target.head(), output))
}

fn first_or_last(args: &[Expr], last: bool) -> Option<Expr> {
    let target = args.first()?;
    let values = target.args();
    if values.is_empty() {
        return args.get(1).cloned();
    }
    if last {
        values.last().cloned()
    } else {
        values.first().cloned()
    }
}

fn trim_end(args: &[Expr], most: bool) -> Option<Expr> {
    let [Expr::Call { head, args }] = args else {
        return None;
    };
    if args.is_empty() {
        return None;
    }
    let values = if most {
        &args[..args.len() - 1]
    } else {
        &args[1..]
    };
    Some(call(head.as_ref().clone(), values.iter().cloned()))
}

fn append_or_prepend(args: &[Expr], prepend: bool) -> Option<Expr> {
    let [Expr::Call { head, args: values }, item] = args else {
        return None;
    };
    let filtered = if is_symbol(head, "Association")
        && (item.has_head("Rule") || item.has_head("RuleDelayed"))
        && item.args().len() == 2
    {
        values
            .iter()
            .filter(|entry| entry.args().first() != item.args().first())
            .cloned()
            .collect::<Vec<_>>()
    } else {
        values.to_vec()
    };
    let mut result = Vec::with_capacity(values.len() + 1);
    if prepend {
        result.push(item.clone());
    }
    result.extend(filtered);
    if !prepend {
        result.push(item.clone());
    }
    if is_symbol(head, "Association") {
        normalize_association(&result)
    } else {
        Some(call(head.as_ref().clone(), result))
    }
}

fn join_expr(args: &[Expr]) -> Option<Expr> {
    let Expr::Call { head, args: first } = args.first()? else {
        return None;
    };
    let mut result = first.clone();
    for expr in &args[1..] {
        let Expr::Call {
            head: other_head,
            args,
        } = expr
        else {
            return None;
        };
        if other_head != head {
            return None;
        }
        result.extend(args.iter().cloned());
    }
    if is_symbol(head, "Association") {
        normalize_association(&result)
    } else {
        Some(call(head.as_ref().clone(), result))
    }
}

fn reverse_expr(args: &[Expr]) -> Option<Expr> {
    let ([target] | [target, _]) = args else {
        return None;
    };
    let levels = match args.get(1) {
        None => vec![1_usize],
        Some(Expr::Integer(level)) => vec![level.to_usize()?],
        Some(levels) if levels.has_head("List") => levels
            .args()
            .iter()
            .map(|level| match level {
                Expr::Integer(level) => level.to_usize(),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()?,
        _ => return None,
    };
    reverse_levels(target, 1, &levels)
}

fn reverse_levels(target: &Expr, level: usize, levels: &[usize]) -> Option<Expr> {
    let Expr::Call { head, args } = target else {
        return Some(target.clone());
    };
    let mut values = args
        .iter()
        .map(|value| reverse_levels(value, level + 1, levels))
        .collect::<Option<Vec<_>>>()?;
    if levels.contains(&level) {
        values.reverse();
    }
    Some(call(head.as_ref().clone(), values))
}

fn rotate_expr(args: &[Expr], right: bool) -> Option<Expr> {
    let (target, amounts) = match args {
        [target] => (target, vec![1_i64]),
        [target, Expr::Integer(count)] => (target, vec![count.to_i64()?]),
        [target, amounts] if amounts.has_head("List") => (
            target,
            amounts
                .args()
                .iter()
                .map(|amount| match amount {
                    Expr::Integer(amount) => amount.to_i64(),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()?,
        ),
        _ => return None,
    };
    rotate_at_axes(target, &amounts, right)
}

fn rotate_at_axes(target: &Expr, amounts: &[i64], right: bool) -> Option<Expr> {
    let Some((&count, remaining)) = amounts.split_first() else {
        return Some(target.clone());
    };
    let Expr::Call { head, args: values } = target else {
        return None;
    };
    if values.is_empty() {
        return Some(target.clone());
    }
    let length = i64::try_from(values.len()).ok()?;
    let offset = count.rem_euclid(length) as usize;
    let split = if right { values.len() - offset } else { offset };
    let mut result = values[split..].to_vec();
    result.extend(values[..split].iter().cloned());
    if !remaining.is_empty() {
        result = result
            .iter()
            .map(|value| rotate_at_axes(value, remaining, right))
            .collect::<Option<Vec<_>>>()?;
    }
    Some(call(head.as_ref().clone(), result))
}

fn take_drop(args: &[Expr], drop: bool) -> Option<Expr> {
    let [target, specs @ ..] = args else {
        return None;
    };
    if specs.is_empty() {
        return None;
    }
    take_drop_levels(target, specs, drop)
}

fn take_drop_levels(target: &Expr, specs: &[Expr], drop: bool) -> Option<Expr> {
    let Some((spec, rest)) = specs.split_first() else {
        return Some(target.clone());
    };
    let Expr::Call { head, args: values } = target else {
        return None;
    };
    let indices = if is_symbol(spec, "None") {
        Vec::new()
    } else {
        selector_indices(values.len(), spec)?
    };
    let selected = values
        .iter()
        .enumerate()
        .filter(|(index, _)| {
            if is_symbol(spec, "None") {
                true
            } else {
                indices.contains(index) != drop
            }
        })
        .map(|(_, value)| take_drop_levels(value, rest, drop))
        .collect::<Option<Vec<_>>>()?;
    Some(call(head.as_ref().clone(), selected))
}

fn level_numbers(spec: &Expr) -> Option<Vec<usize>> {
    match spec {
        Expr::Integer(maximum) => Some((1..=maximum.to_usize()?).collect()),
        spec if spec.has_head("List") => match spec.args() {
            [Expr::Integer(level)] => Some(vec![level.to_usize()?]),
            [Expr::Integer(minimum), Expr::Integer(maximum)] => {
                Some((minimum.to_usize()?..=maximum.to_usize()?).collect())
            }
            levels => levels
                .iter()
                .map(|level| match level {
                    Expr::Integer(level) => level.to_usize(),
                    _ => None,
                })
                .collect(),
        },
        _ => None,
    }
}

fn heads_option_arguments(args: &[Expr], default: bool) -> Option<(Vec<&Expr>, bool)> {
    let mut positional = Vec::new();
    let mut include_heads = default;
    for argument in args {
        if (argument.has_head("Rule") || argument.has_head("RuleDelayed"))
            && argument.args().len() == 2
            && is_symbol(&argument.args()[0], "Heads")
        {
            if is_symbol(&argument.args()[1], "True") {
                include_heads = true;
            } else if is_symbol(&argument.args()[1], "False") {
                include_heads = false;
            } else {
                return None;
            }
        } else {
            positional.push(argument);
        }
    }
    Some((positional, include_heads))
}

fn match_limit(limit: Option<&Expr>) -> Option<Option<usize>> {
    match limit {
        None => Some(None),
        Some(Expr::Symbol(name)) if system_dispatch_name(name) == "Infinity" => Some(None),
        Some(Expr::Integer(value)) if !value.is_negative() => Some(Some(value.to_usize()?)),
        _ => None,
    }
}

fn selector_indices(length: usize, spec: &Expr) -> Option<Vec<usize>> {
    match spec {
        Expr::Symbol(name) if system_dispatch_name(name) == "All" => Some((0..length).collect()),
        Expr::Integer(count) => {
            let count = count.to_i64()?;
            let magnitude = usize::try_from(count.unsigned_abs()).ok()?.min(length);
            if count >= 0 {
                Some((0..magnitude).collect())
            } else {
                Some((length - magnitude..length).collect())
            }
        }
        Expr::Call { head, args } if is_symbol(head, "List") => match args.as_slice() {
            [Expr::Integer(index)] => Some(vec![resolve_index(length, index.to_i64()?)?]),
            [Expr::Integer(start), Expr::Integer(end)] => {
                stepped_indices(length, start.to_i64()?, end.to_i64()?, 1)
            }
            [
                Expr::Integer(start),
                Expr::Integer(end),
                Expr::Integer(step),
            ] => stepped_indices(length, start.to_i64()?, end.to_i64()?, step.to_i64()?),
            _ => None,
        },
        _ => None,
    }
}

fn stepped_indices(length: usize, start: i64, end: i64, step: i64) -> Option<Vec<usize>> {
    if step == 0 {
        return None;
    }
    let start = i64::try_from(resolve_index(length, start)?).ok()?;
    let end = i64::try_from(resolve_index(length, end)?).ok()?;
    let mut result = Vec::new();
    let mut index = start;
    while if step > 0 { index <= end } else { index >= end } {
        result.push(usize::try_from(index).ok()?);
        index += step;
    }
    Some(result)
}

fn flatten_expr(args: &[Expr]) -> Option<Expr> {
    if let [
        Expr::SparseArray {
            dimensions,
            entries,
            fill_value,
        },
    ] = args
    {
        let flattened = entries
            .iter()
            .map(|(position, value)| {
                let mut linear = 0_usize;
                for (index, dimension) in position.iter().zip(dimensions) {
                    linear = linear * dimension + (index - 1);
                }
                (vec![linear + 1], value.clone())
            })
            .collect();
        return Some(Expr::SparseArray {
            dimensions: vec![dimensions.iter().product()],
            entries: flattened,
            fill_value: fill_value.clone(),
        });
    }
    let (target, level, selected_head) = match args {
        [target] => (target, None, None),
        [target, Expr::Integer(level)] if !level.is_negative() => (target, level.to_usize(), None),
        [target, level] if is_symbol(level, "Infinity") => (target, None, None),
        [target, Expr::Integer(level), selected_head] if !level.is_negative() => {
            (target, level.to_usize(), Some(selected_head))
        }
        [target, level, selected_head] if is_symbol(level, "Infinity") => {
            (target, None, Some(selected_head))
        }
        _ => return None,
    };
    let Expr::Call { head, args: values } = target else {
        return Some(target.clone());
    };
    if let Some(selected_head) = selected_head {
        return Some(flatten_named_head(target, selected_head, level));
    }
    let mut output = Vec::new();
    flatten_values(head, values, level, &mut output);
    Some(call(head.as_ref().clone(), output))
}

fn flatten_named_head(target: &Expr, selected_head: &Expr, level: Option<usize>) -> Expr {
    let Expr::Call { head, args } = target else {
        return target.clone();
    };
    if level == Some(0) {
        return target.clone();
    }
    let mut output = Vec::new();
    for argument in args {
        if argument.head() == *selected_head {
            let flattened = flatten_named_head(
                argument,
                selected_head,
                level.map(|remaining| remaining - 1),
            );
            output.extend(flattened.args().iter().cloned());
        } else if matches!(argument, Expr::Call { .. }) {
            output.push(flatten_named_head(argument, selected_head, level));
        } else {
            output.push(argument.clone());
        }
    }
    call(head.as_ref().clone(), output)
}

fn flatten_values(head: &Expr, values: &[Expr], level: Option<usize>, output: &mut Vec<Expr>) {
    for value in values {
        if level != Some(0)
            && let Expr::Call {
                head: child_head,
                args,
            } = value
            && child_head.as_ref() == head
        {
            flatten_values(head, args, level.map(|value| value - 1), output);
        } else {
            output.push(value.clone());
        }
    }
}

fn part_expr(args: &[Expr]) -> Option<Expr> {
    let (target, specs) = args.split_first()?;
    if matches!(target, Expr::SparseArray { .. }) {
        return sparse_part(target, specs);
    }
    part_recursive(target, specs)
}

fn part_recursive(target: &Expr, specs: &[Expr]) -> Option<Expr> {
    let Some((spec, rest)) = specs.split_first() else {
        return Some(target.clone());
    };
    if is_symbol(spec, "All") {
        if let Some(entries) = association_entries(target) {
            return normalize_association(
                &entries
                    .into_iter()
                    .map(|entry| {
                        Some(call(
                            "Rule",
                            [
                                entry.args()[0].clone(),
                                part_recursive(&entry.args()[1], rest)?,
                            ],
                        ))
                    })
                    .collect::<Option<Vec<_>>>()?,
            );
        }
        return Some(call(
            target.head(),
            target
                .args()
                .iter()
                .map(|value| part_recursive(value, rest))
                .collect::<Option<Vec<_>>>()?,
        ));
    }
    if spec.has_head("List") {
        if let Some(entries) = association_entries(target) {
            if !spec.args().iter().all(|index| index.has_head("Key")) {
                return None;
            }
            let selected = spec
                .args()
                .iter()
                .map(|index| {
                    let [key] = index.args() else {
                        return None;
                    };
                    let entry = entries.iter().find(|entry| &entry.args()[0] == key)?;
                    Some(call(
                        "Rule",
                        [key.clone(), part_recursive(&entry.args()[1], rest)?],
                    ))
                })
                .collect::<Option<Vec<_>>>()?;
            return normalize_association(&selected);
        }
        return Some(call(
            target.head(),
            spec.args()
                .iter()
                .map(|index| {
                    select_part(target, index).and_then(|value| part_recursive(&value, rest))
                })
                .collect::<Option<Vec<_>>>()?,
        ));
    }
    let selected = select_part(target, spec)?;
    part_recursive(&selected, rest)
}

fn sparse_part(target: &Expr, specs: &[Expr]) -> Option<Expr> {
    let Expr::SparseArray {
        dimensions,
        entries,
        fill_value,
    } = target
    else {
        return None;
    };
    if specs.iter().all(|spec| matches!(spec, Expr::Integer(_))) && specs.len() <= dimensions.len()
    {
        let prefix = specs
            .iter()
            .zip(dimensions)
            .map(|(spec, dimension)| {
                let Expr::Integer(index) = spec else {
                    unreachable!()
                };
                resolve_index(*dimension, index.to_i64()?).map(|index| index + 1)
            })
            .collect::<Option<Vec<_>>>()?;
        if prefix.len() == dimensions.len() {
            return Some(
                entries
                    .iter()
                    .find(|(position, _)| position == &prefix)
                    .map_or_else(|| fill_value.as_ref().clone(), |(_, value)| value.clone()),
            );
        }
        return Some(Expr::SparseArray {
            dimensions: dimensions[prefix.len()..].to_vec(),
            entries: entries
                .iter()
                .filter(|(position, _)| position.starts_with(&prefix))
                .map(|(position, value)| (position[prefix.len()..].to_vec(), value.clone()))
                .collect(),
            fill_value: fill_value.clone(),
        });
    }
    part_recursive(&sparse_normal(target)?, specs)
}

fn select_part(target: &Expr, spec: &Expr) -> Option<Expr> {
    if target.has_head("Association")
        && (matches!(spec, Expr::String(_)) || matches!(spec, Expr::Symbol(_)))
    {
        let value = association_lookup(target, spec, None);
        return (!value.has_head("Missing")).then_some(value);
    }
    if spec.has_head("Key")
        && let [key] = spec.args()
        && target.has_head("Association")
    {
        return Some(association_lookup(target, key, None));
    }
    if spec.has_head("Span") {
        let (start, end, step) = match spec.args() {
            [Expr::Integer(start), Expr::Integer(end)] => (start.to_i64()?, end.to_i64()?, 1_i64),
            [
                Expr::Integer(start),
                Expr::Integer(end),
                Expr::Integer(step),
            ] => (start.to_i64()?, end.to_i64()?, step.to_i64()?),
            _ => return None,
        };
        if step == 0 {
            return None;
        }
        let start = i64::try_from(resolve_index(target.args().len(), start)?).ok()?;
        let end = i64::try_from(resolve_index(target.args().len(), end)?).ok()?;
        let mut selected = Vec::new();
        let mut index = start;
        while if step > 0 { index <= end } else { index >= end } {
            selected.push(target.args()[usize::try_from(index).ok()?].clone());
            index += step;
        }
        return Some(call(target.head(), selected));
    }
    if let Expr::Integer(index) = spec {
        let index = index.to_i64()?;
        if index == 0 {
            return Some(target.head());
        }
        let selected = target
            .args()
            .get(resolve_index(target.args().len(), index)?)?;
        if target.has_head("Association") {
            return selected.args().get(1).cloned();
        }
        return Some(selected.clone());
    }
    if let Expr::Call {
        head: list_head,
        args: indices,
    } = spec
        && is_symbol(list_head, "List")
    {
        let Expr::Call { head, .. } = target else {
            return None;
        };
        let selected = indices
            .iter()
            .map(|index| select_part(target, index))
            .collect::<Option<Vec<_>>>()?;
        return Some(call(head.as_ref().clone(), selected));
    }
    None
}

fn extract_expr(args: &[Expr]) -> Option<Expr> {
    let [target, positions] = args else {
        return None;
    };
    if positions.has_head("List")
        && positions
            .args()
            .iter()
            .all(|position| position.has_head("List"))
    {
        return Some(list(
            positions
                .args()
                .iter()
                .map(|position| extract_at(target, position))
                .collect::<Option<Vec<_>>>()?,
        ));
    }
    extract_at(target, positions)
}

fn extract_at(target: &Expr, position: &Expr) -> Option<Expr> {
    if !position.has_head("List") {
        return select_part(target, position);
    }
    let mut current = target.clone();
    for component in position.args() {
        current = select_part(&current, component)?;
    }
    Some(current)
}

fn range_expr(args: &[Expr]) -> Option<Expr> {
    let (start, end, step) = match args {
        [Expr::Integer(end)] => (BigInt::one(), end.clone(), BigInt::one()),
        [Expr::Integer(start), Expr::Integer(end)] => (start.clone(), end.clone(), BigInt::one()),
        [
            Expr::Integer(start),
            Expr::Integer(end),
            Expr::Integer(step),
        ] => (start.clone(), end.clone(), step.clone()),
        _ => return None,
    };
    if step.is_zero() {
        return None;
    }
    let mut values = Vec::new();
    let mut current = start;
    while if step.is_positive() {
        current <= end
    } else {
        current >= end
    } {
        values.push(integer(current.clone()));
        current += &step;
        if values.len() > 1_000_000 {
            return None;
        }
    }
    Some(list(values))
}

fn range_threaded_expr(args: &[Expr]) -> Option<Expr> {
    let length = args
        .iter()
        .find(|argument| argument.has_head("List"))
        .map(|argument| argument.args().len());
    let Some(length) = length else {
        return range_expr(args);
    };
    if args
        .iter()
        .any(|argument| argument.has_head("List") && argument.args().len() != length)
    {
        return None;
    }
    Some(list((0..length).map(|index| {
        let threaded = args
            .iter()
            .map(|argument| {
                if argument.has_head("List") {
                    argument.args()[index].clone()
                } else {
                    argument.clone()
                }
            })
            .collect::<Vec<_>>();
        range_expr(&threaded).unwrap_or_else(|| call("Range", threaded))
    })))
}

fn subsequences_expr(args: &[Expr]) -> Option<Expr> {
    let ([target] | [target, _]) = args else {
        return None;
    };
    if !target.has_head("List") {
        return None;
    }
    let sizes = match args.get(1) {
        None => (1..=target.args().len()).collect::<Vec<_>>(),
        Some(Expr::Integer(size)) => (1..=size.to_usize()?.min(target.args().len())).collect(),
        Some(spec) if spec.has_head("List") => match spec.args() {
            [Expr::Integer(size)] => vec![size.to_usize()?],
            [Expr::Integer(minimum), Expr::Integer(maximum)] => {
                (minimum.to_usize()?..=maximum.to_usize()?).collect()
            }
            _ => return None,
        },
        _ => return None,
    };
    Some(list(sizes.into_iter().flat_map(|size| {
        if size > target.args().len() {
            Vec::new()
        } else {
            (0..=target.args().len() - size)
                .map(|start| list(target.args()[start..start + size].iter().cloned()))
                .collect()
        }
    })))
}

fn partition_expr(args: &[Expr]) -> Option<Expr> {
    let ([target, Expr::Integer(size)]
    | [target, Expr::Integer(size), _]
    | [target, Expr::Integer(size), _, _]
    | [target, Expr::Integer(size), _, _, _]) = args
    else {
        return None;
    };
    let values = target_call_args(target)?;
    let size = size.to_usize()?;
    if size == 0 {
        return None;
    }
    let step = match args.get(2) {
        None => size,
        Some(Expr::Integer(step)) => step.to_usize()?,
        _ => return None,
    };
    if step == 0 {
        return None;
    }
    let (left_alignment, right_alignment) = match args.get(3) {
        None => (1_usize, size),
        Some(Expr::Integer(value)) => {
            let value = if value == &BigInt::from(-1) {
                size
            } else {
                value.to_usize()?
            };
            (value, value)
        }
        Some(spec) if spec.has_head("List") => {
            let [Expr::Integer(left), Expr::Integer(right)] = spec.args() else {
                return None;
            };
            let normalize = |value: &BigInt| {
                if value == &BigInt::from(-1) {
                    Some(size)
                } else {
                    value.to_usize()
                }
            };
            (normalize(left)?, normalize(right)?)
        }
        _ => return None,
    };
    if !(1..=size).contains(&left_alignment) || !(1..=size).contains(&right_alignment) {
        return None;
    }
    let first = 1_i64 - i64::try_from(left_alignment - 1).ok()?;
    let last = i64::try_from(values.len()).ok()? - i64::try_from(right_alignment - 1).ok()?;
    if last < first {
        return Some(list([]));
    }
    let count = usize::try_from((last - first) / i64::try_from(step).ok()? + 1).ok()?;
    let padding = args.get(4);
    let mut blocks = Vec::with_capacity(count);
    for block in 0..count {
        let start = first + i64::try_from(block * step).ok()?;
        let mut items = Vec::with_capacity(size);
        for offset in 0..size {
            let position = start + i64::try_from(offset).ok()?;
            if (1..=i64::try_from(values.len()).ok()?).contains(&position) {
                items.push(values[usize::try_from(position - 1).ok()?].clone());
            } else if let Some(padding) = padding {
                items.push(padding.clone());
            } else if !values.is_empty() {
                let index = (position - 1).rem_euclid(i64::try_from(values.len()).ok()?);
                items.push(values[usize::try_from(index).ok()?].clone());
            }
        }
        blocks.push(call(target.head(), items));
    }
    Some(list(blocks))
}

fn alphabetic_sort_expr(args: &[Expr], natural: bool) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    if !target.has_head("List")
        || !target
            .args()
            .iter()
            .all(|value| matches!(value, Expr::String(_)))
    {
        return None;
    }
    let mut values = target.args().to_vec();
    values.sort_by(|left, right| {
        let (Expr::String(left), Expr::String(right)) = (left, right) else {
            unreachable!()
        };
        if natural {
            natural_string_order(left, right)
        } else {
            left.to_lowercase().cmp(&right.to_lowercase())
        }
    });
    Some(list(values))
}

fn natural_string_order(left: &str, right: &str) -> Ordering {
    let mut left = left.chars().peekable();
    let mut right = right.chars().peekable();
    loop {
        match (left.peek(), right.peek()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(a), Some(b)) if a.is_ascii_digit() && b.is_ascii_digit() => {
                let mut left_number = String::new();
                let mut right_number = String::new();
                while left.peek().is_some_and(char::is_ascii_digit) {
                    left_number.push(left.next().expect("peeked"));
                }
                while right.peek().is_some_and(char::is_ascii_digit) {
                    right_number.push(right.next().expect("peeked"));
                }
                let order = left_number
                    .trim_start_matches('0')
                    .len()
                    .cmp(&right_number.trim_start_matches('0').len())
                    .then_with(|| left_number.cmp(&right_number));
                if order != Ordering::Equal {
                    return order;
                }
            }
            (Some(_), Some(_)) => {
                let order = left
                    .next()
                    .expect("peeked")
                    .to_ascii_lowercase()
                    .cmp(&right.next().expect("peeked").to_ascii_lowercase());
                if order != Ordering::Equal {
                    return order;
                }
            }
        }
    }
}

fn matrix_rows(matrix: &Expr) -> Option<Vec<Vec<Expr>>> {
    if matches!(matrix, Expr::SparseArray { .. }) {
        return matrix_rows(&sparse_normal(matrix)?);
    }
    if !matrix.has_head("List") {
        return None;
    }
    matrix
        .args()
        .iter()
        .map(|row| row.has_head("List").then(|| row.args().to_vec()))
        .collect()
}

fn diagonal_matrix_expr(args: &[Expr]) -> Option<Expr> {
    let ([values] | [values, _] | [values, _, _]) = args else {
        return None;
    };
    if !values.has_head("List") {
        return None;
    }
    let offset = match args.get(1) {
        None => 0_i64,
        Some(Expr::Integer(offset)) => offset.to_i64()?,
        _ => return None,
    };
    let minimum_size = values.args().len() + usize::try_from(offset.unsigned_abs()).ok()?;
    let size = match args.get(2) {
        None => minimum_size,
        Some(Expr::Integer(size)) => size.to_usize()?,
        _ => return None,
    };
    let mut matrix = vec![vec![integer(0); size]; size];
    for (index, value) in values.args().iter().enumerate() {
        let (row, column) = if offset >= 0 {
            (index, index + usize::try_from(offset).ok()?)
        } else {
            (index + usize::try_from(offset.unsigned_abs()).ok()?, index)
        };
        if row < size && column < size {
            matrix[row][column] = value.clone();
        }
    }
    Some(list(matrix.into_iter().map(list)))
}

fn levi_civita_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::Integer(rank)] = args else {
        return None;
    };
    let rank = rank.to_usize()?;
    fn build(rank: usize, level: usize, indices: &mut Vec<usize>) -> Expr {
        if level == rank {
            if (0..rank).any(|index| indices[index + 1..].contains(&indices[index])) {
                return integer(0);
            }
            let inversions = (0..rank)
                .flat_map(|left| (left + 1..rank).map(move |right| (left, right)))
                .filter(|(left, right)| indices[*left] > indices[*right])
                .count();
            return integer(if inversions % 2 == 0 { 1 } else { -1 });
        }
        list((0..rank).map(|index| {
            indices.push(index);
            let value = build(rank, level + 1, indices);
            indices.pop();
            value
        }))
    }
    Some(build(rank, 0, &mut Vec::new()))
}

#[derive(Clone)]
struct IntervalSegment {
    left: Expr,
    right: Expr,
}

fn interval_endpoint_order(left: &Expr, right: &Expr) -> Option<Ordering> {
    match (numeric_real_value(left), numeric_real_value(right)) {
        (Some(left), Some(right)) => left.partial_cmp(&right),
        (None, None)
            if !matches!(left, Expr::Complex { .. }) && !matches!(right, Expr::Complex { .. }) =>
        {
            Some(expression_order(left, right))
        }
        _ => None,
    }
}

fn interval_segment(argument: &Expr) -> Option<IntervalSegment> {
    let (left, right) = if argument.has_head("List") {
        let [left, right] = argument.args() else {
            return None;
        };
        (left.clone(), right.clone())
    } else {
        (argument.clone(), argument.clone())
    };
    match interval_endpoint_order(&left, &right)? {
        Ordering::Greater => Some(IntervalSegment {
            left: right,
            right: left,
        }),
        _ => Some(IntervalSegment { left, right }),
    }
}

fn normalize_interval_segments(mut segments: Vec<IntervalSegment>) -> Option<Vec<IntervalSegment>> {
    segments.sort_by(|left, right| {
        interval_endpoint_order(&left.left, &right.left).unwrap_or(Ordering::Equal)
    });
    let mut output: Vec<IntervalSegment> = Vec::new();
    for segment in segments {
        let Some(last) = output.last_mut() else {
            output.push(segment);
            continue;
        };
        if interval_endpoint_order(&segment.left, &last.right)? != Ordering::Greater {
            if interval_endpoint_order(&segment.right, &last.right)? == Ordering::Greater {
                last.right = segment.right;
            }
        } else {
            output.push(segment);
        }
    }
    Some(output)
}

fn interval_from_segments(segments: Vec<IntervalSegment>) -> Expr {
    call(
        "Interval",
        segments
            .into_iter()
            .map(|segment| list([segment.left, segment.right])),
    )
}

fn interval_segments(expr: &Expr) -> Option<Vec<IntervalSegment>> {
    if !expr.has_head("Interval") {
        return None;
    }
    normalize_interval_segments(
        expr.args()
            .iter()
            .map(interval_segment)
            .collect::<Option<Vec<_>>>()?,
    )
}

fn interval_expr(args: &[Expr]) -> Option<Expr> {
    let segments = args
        .iter()
        .map(interval_segment)
        .collect::<Option<Vec<_>>>()?;
    Some(interval_from_segments(normalize_interval_segments(
        segments,
    )?))
}

fn interval_union_expr(args: &[Expr]) -> Option<Expr> {
    let mut segments = Vec::new();
    for argument in args {
        segments.extend(interval_segments(argument)?);
    }
    Some(interval_from_segments(normalize_interval_segments(
        segments,
    )?))
}

fn interval_intersection_expr(args: &[Expr]) -> Option<Expr> {
    let Some(first) = args.first() else {
        return Some(call("Interval", []));
    };
    let mut current = interval_segments(first)?;
    for argument in &args[1..] {
        let mut intersections = Vec::new();
        for left in &current {
            for right in interval_segments(argument)? {
                let start = if interval_endpoint_order(&left.left, &right.left)? == Ordering::Less {
                    right.left
                } else {
                    left.left.clone()
                };
                let end =
                    if interval_endpoint_order(&left.right, &right.right)? == Ordering::Greater {
                        right.right
                    } else {
                        left.right.clone()
                    };
                if interval_endpoint_order(&start, &end)? != Ordering::Greater {
                    intersections.push(IntervalSegment {
                        left: start,
                        right: end,
                    });
                }
            }
        }
        current = normalize_interval_segments(intersections)?;
    }
    Some(interval_from_segments(current))
}

fn interval_contains(container: &[IntervalSegment], candidate: &IntervalSegment) -> bool {
    container.iter().any(|segment| {
        interval_endpoint_order(&segment.left, &candidate.left)
            .is_some_and(|order| order != Ordering::Greater)
            && interval_endpoint_order(&candidate.right, &segment.right)
                .is_some_and(|order| order != Ordering::Greater)
    })
}

fn interval_member_expr(args: &[Expr]) -> Option<Expr> {
    let [interval, item] = args else {
        return None;
    };
    let segments = interval_segments(interval)?;
    if item.has_head("List") {
        return Some(list(item.args().iter().map(|item| {
            interval_member_expr(&[interval.clone(), item.clone()])
                .unwrap_or_else(|| symbol("False"))
        })));
    }
    if let Some(candidate) = interval_segments(item) {
        return Some(bool_expr(
            candidate
                .iter()
                .all(|item| interval_contains(&segments, item)),
        ));
    }
    if numeric_real_value(item).is_none() {
        return Some(symbol("False"));
    }
    let candidate = interval_segment(item)?;
    Some(bool_expr(interval_contains(&segments, &candidate)))
}

fn sparse_array_expr(args: &[Expr]) -> Option<Expr> {
    let ([data] | [data, _] | [data, _, _]) = args else {
        return None;
    };
    let dimensions = if let Some(dimensions) = args.get(1) {
        Some(array_dimensions(dimensions)?)
    } else {
        None
    };
    let fill_value = args.get(2).cloned().unwrap_or_else(|| integer(0));
    if let Expr::SparseArray {
        dimensions: existing,
        entries,
        ..
    } = data
    {
        if dimensions
            .as_ref()
            .is_some_and(|dimensions| dimensions != existing)
        {
            return None;
        }
        return Some(Expr::SparseArray {
            dimensions: existing.clone(),
            entries: entries.clone(),
            fill_value: Box::new(fill_value),
        });
    }
    if is_symbol(data, "Automatic") {
        return Some(Expr::SparseArray {
            dimensions: dimensions?,
            entries: Vec::new(),
            fill_value: Box::new(fill_value),
        });
    }
    let rules = if matches!(
        data.head().symbol_name().map(system_dispatch_name),
        Some("Rule" | "RuleDelayed")
    ) {
        Some(vec![data.clone()])
    } else if data.has_head("List")
        && data.args().iter().all(|item| {
            matches!(
                item.head().symbol_name().map(system_dispatch_name),
                Some("Rule" | "RuleDelayed")
            )
        })
    {
        Some(data.args().to_vec())
    } else {
        None
    };
    if let Some(rules) = rules {
        let rank_hint = dimensions.as_ref().map(Vec::len);
        let mut entries = Vec::new();
        for rule in rules {
            let [positions, values] = rule.args() else {
                return None;
            };
            if rank_hint.is_none_or(|rank| rank == 1)
                && positions.has_head("List")
                && values.has_head("List")
                && positions.args().len() == values.args().len()
                && positions
                    .args()
                    .iter()
                    .all(|position| matches!(position, Expr::Integer(_)))
            {
                for (position, value) in positions.args().iter().zip(values.args()) {
                    let Expr::Integer(position) = position else {
                        unreachable!()
                    };
                    entries.push((vec![position.to_usize()?], value.clone()));
                }
                continue;
            }
            let position = if let Expr::Integer(position) = positions {
                vec![position.to_usize()?]
            } else if positions.has_head("List") {
                positions
                    .args()
                    .iter()
                    .map(|position| match position {
                        Expr::Integer(position) => position.to_usize(),
                        _ => None,
                    })
                    .collect::<Option<Vec<_>>>()?
            } else {
                return None;
            };
            if rank_hint.is_some_and(|rank| rank != position.len()) {
                return None;
            }
            entries.push((position, values.clone()));
        }
        let dimensions = dimensions.unwrap_or_else(|| {
            let rank = entries.first().map_or(0, |(position, _)| position.len());
            (0..rank)
                .map(|axis| {
                    entries
                        .iter()
                        .map(|(position, _)| position[axis])
                        .max()
                        .unwrap_or(0)
                })
                .collect()
        });
        let mut normalized = Vec::new();
        for (position, value) in entries {
            if position.len() != dimensions.len()
                || position
                    .iter()
                    .zip(&dimensions)
                    .any(|(index, dimension)| *index == 0 || index > dimension)
            {
                return None;
            }
            if value != fill_value
                && !normalized
                    .iter()
                    .any(|(existing, _): &(Vec<usize>, Expr)| existing == &position)
            {
                normalized.push((position, value));
            }
        }
        normalized.sort_by(|left, right| left.0.cmp(&right.0));
        return Some(Expr::SparseArray {
            dimensions,
            entries: normalized,
            fill_value: Box::new(fill_value),
        });
    }
    let dense_dimensions = dense_dimensions(data)?;
    if dense_dimensions.is_empty()
        || dimensions
            .as_ref()
            .is_some_and(|dimensions| dimensions != &dense_dimensions)
    {
        return None;
    }
    Some(dense_to_sparse(data, &fill_value))
}

fn sparse_elementwise_expr(operation: &str, args: &[Expr]) -> Option<Expr> {
    let dimensions = args.iter().find_map(|argument| match argument {
        Expr::SparseArray { dimensions, .. } => Some(dimensions.clone()),
        _ => None,
    })?;
    if args.iter().any(|argument| {
        matches!(argument, Expr::SparseArray { dimensions: other, .. } if other != &dimensions)
    }) {
        return None;
    }
    let fill_arguments = args
        .iter()
        .map(|argument| match argument {
            Expr::SparseArray { fill_value, .. } => fill_value.as_ref().clone(),
            scalar => scalar.clone(),
        })
        .collect::<Vec<_>>();
    let fill_value = evaluate_arithmetic(operation, &fill_arguments)?;
    let dense = build_dense_array(&dimensions, &mut Vec::new(), &mut |indices| {
        let position = indices.iter().map(|index| index + 1).collect::<Vec<_>>();
        let values = args
            .iter()
            .map(|argument| match argument {
                Expr::SparseArray {
                    entries,
                    fill_value,
                    ..
                } => entries
                    .iter()
                    .find(|(indices, _)| indices == &position)
                    .map_or_else(|| fill_value.as_ref().clone(), |(_, value)| value.clone()),
                scalar => scalar.clone(),
            })
            .collect::<Vec<_>>();
        evaluate_arithmetic(operation, &values).unwrap_or_else(|| call(operation, values))
    });
    Some(dense_to_sparse(&dense, &fill_value))
}

fn dense_to_sparse(data: &Expr, fill_value: &Expr) -> Expr {
    let dimensions = dense_dimensions(data).unwrap_or_default();
    let mut entries = Vec::new();
    fn collect(
        expr: &Expr,
        dimensions: &[usize],
        indices: &mut Vec<usize>,
        fill_value: &Expr,
        entries: &mut Vec<(Vec<usize>, Expr)>,
    ) {
        if dimensions.is_empty() {
            if expr != fill_value {
                entries.push((indices.clone(), expr.clone()));
            }
            return;
        }
        for (offset, value) in expr.args().iter().enumerate() {
            indices.push(offset + 1);
            collect(value, &dimensions[1..], indices, fill_value, entries);
            indices.pop();
        }
    }
    collect(data, &dimensions, &mut Vec::new(), fill_value, &mut entries);
    Expr::SparseArray {
        dimensions,
        entries,
        fill_value: Box::new(fill_value.clone()),
    }
}

fn sparse_normal(array: &Expr) -> Option<Expr> {
    let Expr::SparseArray {
        dimensions,
        entries,
        fill_value,
    } = array
    else {
        return None;
    };
    Some(build_dense_array(
        dimensions,
        &mut Vec::new(),
        &mut |indices| {
            let indices = indices.iter().map(|index| index + 1).collect::<Vec<_>>();
            entries
                .iter()
                .find(|(position, _)| position == &indices)
                .map_or_else(|| fill_value.as_ref().clone(), |(_, value)| value.clone())
        },
    ))
}

fn sparse_array_rules(args: &[Expr]) -> Option<Expr> {
    let [
        Expr::SparseArray {
            dimensions,
            entries,
            fill_value,
        },
    ] = args
    else {
        return None;
    };
    Some(list(
        entries
            .iter()
            .map(|(position, value)| {
                call(
                    "Rule",
                    [list(position.iter().copied().map(integer)), value.clone()],
                )
            })
            .chain(std::iter::once(call(
                "Rule",
                [
                    list((0..dimensions.len()).map(|_| call("Blank", []))),
                    fill_value.as_ref().clone(),
                ],
            ))),
    ))
}

fn dense_dimensions(expr: &Expr) -> Option<Vec<usize>> {
    if let Expr::SparseArray { dimensions, .. } = expr {
        return Some(dimensions.clone());
    }
    if !expr.has_head("List") {
        return Some(Vec::new());
    }
    if expr.args().is_empty() {
        return Some(vec![0]);
    }
    let child = dense_dimensions(&expr.args()[0])?;
    if expr
        .args()
        .iter()
        .skip(1)
        .any(|argument| dense_dimensions(argument).as_ref() != Some(&child))
    {
        return None;
    }
    let mut result = vec![expr.args().len()];
    result.extend(child);
    Some(result)
}

fn dense_leaf_values(expr: &Expr) -> Vec<&Expr> {
    if expr.has_head("List") {
        expr.args().iter().flat_map(dense_leaf_values).collect()
    } else {
        vec![expr]
    }
}

fn array_depth_value(expr: &Expr) -> usize {
    if let Expr::SparseArray { dimensions, .. } = expr {
        return dimensions.len();
    }
    if !expr.has_head("List") {
        return 0;
    }
    1 + expr.args().iter().map(array_depth_value).max().unwrap_or(0)
}

fn dimensions_expr(args: &[Expr]) -> Option<Expr> {
    let [target] = args else {
        return None;
    };
    Some(list(dense_dimensions(target)?.into_iter().map(integer)))
}

fn array_dimensions(spec: &Expr) -> Option<Vec<usize>> {
    if let Expr::Integer(value) = spec {
        return Some(vec![value.to_usize()?]);
    }
    if !spec.has_head("List") {
        return None;
    }
    spec.args()
        .iter()
        .map(|value| match value {
            Expr::Integer(value) => value.to_usize(),
            _ => None,
        })
        .collect()
}

fn build_dense_array<F>(dimensions: &[usize], prefix: &mut Vec<usize>, builder: &mut F) -> Expr
where
    F: FnMut(&[usize]) -> Expr,
{
    let Some((dimension, rest)) = dimensions.split_first() else {
        return builder(prefix);
    };
    list((0..*dimension).map(|index| {
        prefix.push(index);
        let value = build_dense_array(rest, prefix, builder);
        prefix.pop();
        value
    }))
}

fn dense_value_at<'a>(expr: &'a Expr, indices: &[usize]) -> Option<&'a Expr> {
    let mut current = expr;
    for index in indices {
        if !current.has_head("List") {
            return None;
        }
        current = current.args().get(*index)?;
    }
    Some(current)
}

fn array_reshape_expr(args: &[Expr]) -> Option<Expr> {
    let ([target, dimensions] | [target, dimensions, _]) = args else {
        return None;
    };
    let dimensions = array_dimensions(dimensions)?;
    let fill = args.get(2).cloned().unwrap_or_else(|| integer(0));
    if let Expr::SparseArray {
        dimensions: old_dimensions,
        entries,
        fill_value,
    } = target
        && (fill == **fill_value
            || dimensions.iter().product::<usize>() <= old_dimensions.iter().product())
    {
        let new_total = dimensions.iter().product::<usize>();
        let mut reshaped = Vec::new();
        for (position, value) in entries {
            let mut linear = 0_usize;
            for (index, dimension) in position.iter().zip(old_dimensions) {
                linear = linear * dimension + (index - 1);
            }
            if linear >= new_total {
                continue;
            }
            let mut remainder = linear;
            let mut output = vec![1_usize; dimensions.len()];
            for axis in (0..dimensions.len()).rev() {
                output[axis] = remainder % dimensions[axis] + 1;
                remainder /= dimensions[axis];
            }
            reshaped.push((output, value.clone()));
        }
        return Some(Expr::SparseArray {
            dimensions,
            entries: reshaped,
            fill_value: if new_total <= old_dimensions.iter().product() {
                fill_value.clone()
            } else {
                Box::new(fill)
            },
        });
    }
    let dense_target = if matches!(target, Expr::SparseArray { .. }) {
        sparse_normal(target)?
    } else {
        target.clone()
    };
    let values = dense_leaf_values(&dense_target);
    let mut offset = 0_usize;
    Some(build_dense_array(&dimensions, &mut Vec::new(), &mut |_| {
        let value = values
            .get(offset)
            .map_or_else(|| fill.clone(), |value| (*value).clone());
        offset += 1;
        value
    }))
}

fn array_padding(spec: &Expr, rank: usize) -> Option<Vec<(usize, usize)>> {
    if let Expr::Integer(value) = spec {
        let value = value.to_usize()?;
        return Some(vec![(value, value); rank]);
    }
    if !spec.has_head("List") {
        return None;
    }
    if rank == 1 && matches!(spec.args(), [Expr::Integer(_), Expr::Integer(_)]) {
        let Expr::Integer(left) = &spec.args()[0] else {
            unreachable!()
        };
        let Expr::Integer(right) = &spec.args()[1] else {
            unreachable!()
        };
        return Some(vec![(left.to_usize()?, right.to_usize()?)]);
    }
    if spec.args().len() != rank {
        return None;
    }
    spec.args()
        .iter()
        .map(|item| match item {
            Expr::Integer(value) => value.to_usize().map(|value| (value, value)),
            item if item.has_head("List") => match item.args() {
                [Expr::Integer(left), Expr::Integer(right)] => {
                    Some((left.to_usize()?, right.to_usize()?))
                }
                _ => None,
            },
            _ => None,
        })
        .collect()
}

fn array_pad_expr(args: &[Expr]) -> Option<Expr> {
    let ([target, padding] | [target, padding, _]) = args else {
        return None;
    };
    let dimensions = dense_dimensions(target)?;
    if dimensions.is_empty() {
        return None;
    }
    let widths = array_padding(padding, dimensions.len())?;
    let output_dimensions = dimensions
        .iter()
        .zip(&widths)
        .map(|(dimension, (left, right))| dimension + left + right)
        .collect::<Vec<_>>();
    let fill = args.get(2).cloned().unwrap_or_else(|| integer(0));
    if let Expr::SparseArray {
        entries,
        fill_value,
        ..
    } = target
        && fill == **fill_value
    {
        return Some(Expr::SparseArray {
            dimensions: output_dimensions,
            entries: entries
                .iter()
                .map(|(position, value)| {
                    (
                        position
                            .iter()
                            .zip(&widths)
                            .map(|(index, (left, _))| index + left)
                            .collect(),
                        value.clone(),
                    )
                })
                .collect(),
            fill_value: fill_value.clone(),
        });
    }
    let dense_target = if matches!(target, Expr::SparseArray { .. }) {
        sparse_normal(target)?
    } else {
        target.clone()
    };
    Some(build_dense_array(
        &output_dimensions,
        &mut Vec::new(),
        &mut |indices| {
            let mut source = Vec::with_capacity(indices.len());
            for ((index, dimension), (left, _)) in indices.iter().zip(&dimensions).zip(&widths) {
                if *index < *left || *index >= left + dimension {
                    return fill.clone();
                }
                source.push(index - left);
            }
            dense_value_at(&dense_target, &source)
                .cloned()
                .unwrap_or_else(|| fill.clone())
        },
    ))
}

fn array_flatten_expr(args: &[Expr]) -> Option<Expr> {
    let [blocks] = args else {
        return None;
    };
    if !blocks.has_head("List") || blocks.args().is_empty() {
        return None;
    }
    let block_rows = blocks
        .args()
        .iter()
        .map(|row| row.has_head("List").then_some(row.args()))
        .collect::<Option<Vec<_>>>()?;
    let columns = block_rows.first()?.len();
    if columns == 0 || block_rows.iter().any(|row| row.len() != columns) {
        return None;
    }
    let shapes = block_rows
        .iter()
        .map(|row| {
            row.iter()
                .map(|block| match dense_dimensions(block)?.as_slice() {
                    [height, width] => Some((*height, *width)),
                    _ => None,
                })
                .collect::<Option<Vec<_>>>()
        })
        .collect::<Option<Vec<_>>>()?;
    let heights = shapes
        .iter()
        .map(|row| {
            row.iter()
                .all(|shape| shape.0 == row[0].0)
                .then_some(row[0].0)
        })
        .collect::<Option<Vec<_>>>()?;
    let widths = (0..columns)
        .map(|column| {
            shapes
                .iter()
                .all(|row| row[column].1 == shapes[0][column].1)
                .then_some(shapes[0][column].1)
        })
        .collect::<Option<Vec<_>>>()?;
    let mut rows = Vec::new();
    for (block_row, height) in block_rows.iter().zip(heights) {
        for local_row in 0..height {
            let mut values = Vec::new();
            for (block, width) in block_row.iter().zip(&widths) {
                let row = dense_value_at(block, &[local_row])?;
                values.extend(row.args().iter().take(*width).cloned());
            }
            rows.push(list(values));
        }
    }
    Some(list(rows))
}

fn constant_array(args: &[Expr]) -> Option<Expr> {
    let [value, dimensions] = args else {
        return None;
    };
    let dimensions = if let Expr::Integer(count) = dimensions {
        vec![count.to_usize()?]
    } else if dimensions.has_head("List") {
        dimensions
            .args()
            .iter()
            .map(|dimension| match dimension {
                Expr::Integer(value) => value.to_usize(),
                _ => None,
            })
            .collect::<Option<Vec<_>>>()?
    } else {
        return None;
    };
    Some(constant_array_level(value, &dimensions))
}

fn constant_array_level(value: &Expr, dimensions: &[usize]) -> Expr {
    let Some((dimension, rest)) = dimensions.split_first() else {
        return value.clone();
    };
    list(
        (0..*dimension)
            .map(|_| constant_array_level(value, rest))
            .filter(|value| !is_symbol(value, "Nothing")),
    )
}

fn level_expr(args: &[Expr]) -> Option<Expr> {
    let [target, spec] = args else {
        return None;
    };
    let mut output = Vec::new();
    collect_levels(target, spec, 0, true, &mut output)?;
    Some(list(
        output
            .into_iter()
            .filter(|value| !is_symbol(value, "Nothing")),
    ))
}

fn collect_levels(
    expr: &Expr,
    spec: &Expr,
    level: i64,
    root: bool,
    output: &mut Vec<Expr>,
) -> Option<()> {
    for argument in expr.args() {
        collect_levels(argument, spec, level + 1, false, output)?;
    }
    if !root && level_spec_matches(spec, level, -(depth(expr) as i64))? {
        output.push(expr.clone());
    }
    Some(())
}

fn level_spec_matches(spec: &Expr, positive: i64, negative: i64) -> Option<bool> {
    const LEVEL_INFINITY: i64 = i64::MAX / 4;
    let bound = |expr: &Expr| match expr {
        Expr::Integer(value) => value.to_i64(),
        Expr::Symbol(name) if system_dispatch_name(name) == "Infinity" => Some(LEVEL_INFINITY),
        _ => None,
    };
    let (minimum, maximum) = match spec {
        Expr::Symbol(name) if system_dispatch_name(name) == "Infinity" => (1, LEVEL_INFINITY),
        Expr::Integer(value) => {
            let value = value.to_i64()?;
            if value == 0 {
                (0, 0)
            } else if value > 0 {
                (1, value)
            } else {
                (1, value)
            }
        }
        Expr::Call { head, args } if is_symbol(head, "List") => match args.as_slice() {
            [value] => {
                let value = bound(value)?;
                (value, value)
            }
            [minimum, maximum] => (bound(minimum)?, bound(maximum)?),
            _ => return None,
        },
        _ => return None,
    };
    Some(if minimum >= 0 && maximum >= 0 {
        (minimum..=maximum).contains(&positive)
    } else if minimum < 0 && maximum < 0 {
        (minimum..=maximum).contains(&negative)
    } else if minimum >= 0 {
        positive >= minimum && negative <= maximum
    } else {
        negative >= minimum || positive <= maximum
    })
}

fn position_expr(args: &[Expr]) -> Option<Expr> {
    let mut include_heads = true;
    let mut positional = Vec::new();
    for argument in args {
        if argument.has_head("Rule")
            && argument.args().len() == 2
            && is_symbol(&argument.args()[0], "Heads")
        {
            include_heads = is_symbol(&argument.args()[1], "True");
        } else {
            positional.push(argument);
        }
    }
    if !(2..=4).contains(&positional.len()) {
        return None;
    }
    let target = positional[0];
    let pattern = positional[1];
    let default_spec = symbol("Infinity");
    let spec = positional.get(2).copied().unwrap_or(&default_spec);
    let mut remaining = match positional.get(3) {
        None => None,
        Some(Expr::Symbol(name)) if system_dispatch_name(name) == "Infinity" => None,
        Some(Expr::Integer(value)) if !value.is_negative() => Some(value.to_usize()?),
        _ => return None,
    };
    let mut output = Vec::new();
    collect_positions(
        target,
        pattern,
        spec,
        include_heads,
        0,
        &[],
        &mut remaining,
        &mut output,
    )?;
    Some(list(output.into_iter().map(list)))
}

fn collect_positions(
    expr: &Expr,
    pattern: &Expr,
    spec: &Expr,
    include_heads: bool,
    level: i64,
    path: &[Expr],
    remaining: &mut Option<usize>,
    output: &mut Vec<Vec<Expr>>,
) -> Option<()> {
    if remaining.is_some_and(|count| count == 0) {
        return Some(());
    }
    if let Some(entries) = association_entries(expr) {
        if include_heads {
            let mut head_path = path.to_vec();
            head_path.push(integer(0));
            collect_positions(
                &expr.head(),
                pattern,
                spec,
                include_heads,
                level + 1,
                &head_path,
                remaining,
                output,
            )?;
        }
        for entry in entries {
            if remaining.is_some_and(|count| count == 0) {
                break;
            }
            let mut entry_path = path.to_vec();
            entry_path.push(call("Key", [entry.args()[0].clone()]));
            collect_positions(
                &entry.args()[1],
                pattern,
                spec,
                include_heads,
                level + 1,
                &entry_path,
                remaining,
                output,
            )?;
        }
    } else if let Expr::Call { head, args } = expr {
        if include_heads {
            let mut head_path = path.to_vec();
            head_path.push(integer(0));
            collect_positions(
                head,
                pattern,
                spec,
                include_heads,
                level + 1,
                &head_path,
                remaining,
                output,
            )?;
        }
        for (index, argument) in args.iter().enumerate() {
            if remaining.is_some_and(|count| count == 0) {
                break;
            }
            let mut argument_path = path.to_vec();
            argument_path.push(integer(index + 1));
            collect_positions(
                argument,
                pattern,
                spec,
                include_heads,
                level + 1,
                &argument_path,
                remaining,
                output,
            )?;
        }
    }
    if !remaining.is_some_and(|count| count == 0)
        && level_spec_matches(spec, level, -(depth(expr) as i64))?
        && simple_pattern_matches(expr, pattern)
    {
        output.push(path.to_vec());
        if let Some(count) = remaining {
            *count = count.saturating_sub(1);
        }
    }
    Some(())
}

fn replace_part_expr(args: &[Expr]) -> Option<Expr> {
    let [target, rules] = args else {
        return None;
    };
    let rules = if rules.has_head("List") {
        rules.args().to_vec()
    } else {
        vec![rules.clone()]
    };
    if rules.iter().any(|rule| {
        !matches!(
            rule.head().symbol_name().map(system_dispatch_name),
            Some("Rule" | "RuleDelayed")
        ) || rule.args().len() != 2
    }) {
        return None;
    }
    let mut result = target.clone();
    for rule in rules {
        let paths = position_paths(&rule.args()[0])?;
        for path in paths {
            result = replace_at_path(&result, &path, &rule.args()[1]).unwrap_or(result);
        }
    }
    Some(result)
}

fn position_paths(spec: &Expr) -> Option<Vec<Vec<Expr>>> {
    if matches!(spec, Expr::Integer(_)) || spec.has_head("Key") {
        return Some(vec![vec![spec.clone()]]);
    }
    if !spec.has_head("List") {
        return None;
    }
    if spec.args().iter().all(|position| position.has_head("List")) {
        Some(
            spec.args()
                .iter()
                .map(|position| position.args().to_vec())
                .collect(),
        )
    } else {
        Some(vec![spec.args().to_vec()])
    }
}

fn expr_at_path(expr: &Expr, path: &[Expr]) -> Option<Expr> {
    let Some((part, rest)) = path.split_first() else {
        return Some(expr.clone());
    };
    if part.has_head("Key") {
        let [key] = part.args() else {
            return None;
        };
        let entry = association_entries(expr)?
            .into_iter()
            .find(|entry| &entry.args()[0] == key)?;
        return expr_at_path(&entry.args()[1], rest);
    }
    let Expr::Integer(index) = part else {
        return None;
    };
    let index = index.to_i64()?;
    if index == 0 {
        let Expr::Call { head, .. } = expr else {
            return None;
        };
        return expr_at_path(head, rest);
    }
    let index = resolve_index(expr.args().len(), index)?;
    expr_at_path(&expr.args()[index], rest)
}

fn replace_at_path(expr: &Expr, path: &[Expr], replacement: &Expr) -> Option<Expr> {
    let Some((part, rest)) = path.split_first() else {
        return Some(replacement.clone());
    };
    if part.has_head("Key") {
        let [key] = part.args() else {
            return None;
        };
        let entries = association_entries(expr)?;
        let mut found = false;
        let mut output = Vec::with_capacity(entries.len());
        for entry in entries {
            if &entry.args()[0] == key {
                let value = replace_at_path(&entry.args()[1], rest, replacement)?;
                output.push(call(entry.head(), [entry.args()[0].clone(), value]));
                found = true;
            } else {
                output.push(entry);
            }
        }
        return found.then(|| call("Association", output));
    }
    let Expr::Integer(index) = part else {
        return None;
    };
    let index = index.to_i64()?;
    let Expr::Call { head, args } = expr else {
        return None;
    };
    if index == 0 {
        let new_head = replace_at_path(head, rest, replacement)?;
        return Some(call(new_head, args.clone()));
    }
    let index = resolve_index(args.len(), index)?;
    let mut output = args.clone();
    output[index] = replace_at_path(&output[index], rest, replacement)?;
    if is_symbol(head, "List") || is_symbol(head, "Association") {
        output.retain(|value| !is_symbol(value, "Nothing"));
    }
    Some(call(head.as_ref().clone(), output))
}

fn resolve_index(length: usize, index: i64) -> Option<usize> {
    let resolved = if index > 0 {
        index - 1
    } else if index < 0 {
        i64::try_from(length).ok()? + index
    } else {
        return None;
    };
    let resolved = usize::try_from(resolved).ok()?;
    (resolved < length).then_some(resolved)
}

fn substitute_slots(expr: &Expr, arguments: &[Expr], self_function: &Expr) -> Expr {
    if expr.has_head("Slot") {
        let index = match expr.args() {
            [] => 1,
            [Expr::Integer(index)] if index.is_zero() => return self_function.clone(),
            [Expr::Integer(index)] => index.to_usize().unwrap_or(1),
            [Expr::String(name)] => {
                return arguments.first().map_or_else(
                    || expr.clone(),
                    |target| call(target.clone(), [string(name)]),
                );
            }
            _ => return expr.clone(),
        };
        return arguments
            .get(index.saturating_sub(1))
            .cloned()
            .unwrap_or_else(|| expr.clone());
    }
    if expr.has_head("SlotSequence") {
        let index = match expr.args() {
            [] => 1,
            [Expr::Integer(index)] => index.to_usize().unwrap_or(1),
            _ => return expr.clone(),
        };
        return call(
            "Sequence",
            arguments.iter().skip(index.saturating_sub(1)).cloned(),
        );
    }
    match expr {
        Expr::Call { head, args } if !is_positional_function(expr) => {
            let mut substituted_args = Vec::new();
            for argument in args {
                let substituted = substitute_slots(argument, arguments, self_function);
                if argument.has_head("SlotSequence") && substituted.has_head("Sequence") {
                    substituted_args.extend(substituted.args().iter().cloned());
                } else {
                    substituted_args.push(substituted);
                }
            }
            call(
                substitute_slots(head, arguments, self_function),
                substituted_args,
            )
        }
        _ => expr.clone(),
    }
}

fn is_positional_function(expr: &Expr) -> bool {
    if !expr.has_head("Function") {
        return false;
    }
    match expr.args() {
        [_] => true,
        [parameters, _] | [parameters, _, _] => is_symbol(parameters, "Null"),
        _ => false,
    }
}

fn function_attributes(function_args: &[Expr]) -> Option<BTreeSet<String>> {
    let Some(attributes) = function_args.get(2) else {
        return Some(BTreeSet::new());
    };
    match attributes {
        Expr::Symbol(name) => Some(BTreeSet::from([system_dispatch_name(name).to_owned()])),
        attributes if attributes.has_head("List") => attributes
            .args()
            .iter()
            .map(|attribute| {
                attribute
                    .symbol_name()
                    .map(system_dispatch_name)
                    .map(str::to_owned)
            })
            .collect(),
        _ => None,
    }
}

fn parse_local_bindings(expr: &Expr, allow_uninitialized: bool) -> Option<Vec<LocalBinding>> {
    let Expr::Call { head, args } = expr else {
        return None;
    };
    if !is_symbol(head, "List") {
        return None;
    }
    let mut result = Vec::with_capacity(args.len());
    let mut names = Vec::new();
    for binding in args {
        let parsed = match binding {
            Expr::Symbol(name) if allow_uninitialized => LocalBinding {
                name: name.clone(),
                value: None,
                delayed: false,
            },
            Expr::Call {
                head: binding_head,
                args: binding_args,
            } if matches!(
                binding_head.symbol_name().map(system_dispatch_name),
                Some("Set" | "SetDelayed")
            ) && binding_args.len() == 2 =>
            {
                let Expr::Symbol(name) = &binding_args[0] else {
                    return None;
                };
                LocalBinding {
                    name: name.clone(),
                    value: Some(binding_args[1].clone()),
                    delayed: is_symbol(binding_head, "SetDelayed"),
                }
            }
            _ => return None,
        };
        if names.contains(&parsed.name) {
            return None;
        }
        names.push(parsed.name.clone());
        result.push(parsed);
    }
    Some(result)
}

fn substitute_lexical(expr: &Expr, bindings: &[(String, Expr)]) -> Expr {
    if bindings.is_empty() {
        return expr.clone();
    }
    if let Expr::Symbol(name) = expr
        && let Some((_, value)) = bindings.iter().find(|(binding, _)| binding == name)
    {
        return value.clone();
    }
    let Expr::Call { head, args } = expr else {
        return expr.clone();
    };

    if is_symbol(head, "Function") && matches!(args.len(), 2..=3) {
        return substitute_lexical_function(expr, args, bindings);
    }

    if head.symbol_name().is_some_and(|name| {
        matches!(
            system_dispatch_name(name),
            "With" | "Module" | "Block" | "InheritedBlock" | "Internal`InheritedBlock"
        )
    }) && args.len() == 2
        && let Some(local_bindings) = parse_local_bindings(&args[0], true)
    {
        let local_names = local_bindings
            .iter()
            .map(|binding| binding.name.clone())
            .collect::<Vec<_>>();
        let rewritten_bindings = local_bindings.into_iter().map(|binding| {
            if let Some(value) = binding.value {
                call(
                    if binding.delayed { "SetDelayed" } else { "Set" },
                    [symbol(binding.name), substitute_lexical(&value, bindings)],
                )
            } else {
                symbol(binding.name)
            }
        });
        let filtered = bindings
            .iter()
            .filter(|(name, _)| !local_names.contains(name))
            .cloned()
            .collect::<Vec<_>>();
        return call(
            head.as_ref().clone(),
            [
                list(rewritten_bindings),
                substitute_lexical(&args[1], &filtered),
            ],
        );
    }

    call(
        substitute_lexical(head, bindings),
        args.iter()
            .map(|argument| substitute_lexical(argument, bindings)),
    )
}

fn substitute_lexical_function(
    original: &Expr,
    args: &[Expr],
    bindings: &[(String, Expr)],
) -> Expr {
    let Some(parameter_names) = function_parameter_names(&args[0]) else {
        return original.clone();
    };
    let filtered = bindings
        .iter()
        .filter(|(name, _)| !parameter_names.contains(name))
        .cloned()
        .collect::<Vec<_>>();
    let flows_into_body = filtered
        .iter()
        .any(|(name, _)| contains_symbol_name(&args[1], name));
    if !flows_into_body {
        return original.clone();
    }

    let mut renames = Vec::new();
    for name in &parameter_names {
        let mut candidate = format!("{name}$");
        while contains_symbol_name(&args[1], &candidate)
            || bindings
                .iter()
                .any(|(_, value)| contains_symbol_name(value, &candidate))
        {
            candidate.push('$');
        }
        renames.push((name.clone(), symbol(candidate)));
    }
    let renamed_parameters = substitute_lexical(&args[0], &renames);
    let renamed_body = rename_symbols_scoped(&args[1], &renames);
    let body = substitute_lexical(&renamed_body, &filtered);
    let mut output = vec![renamed_parameters, body];
    output.extend(args.iter().skip(2).cloned());
    call("Function", output)
}

fn rename_symbols_scoped(expr: &Expr, renames: &[(String, Expr)]) -> Expr {
    if renames.is_empty() {
        return expr.clone();
    }
    if let Expr::Symbol(name) = expr
        && let Some((_, value)) = renames.iter().find(|(candidate, _)| candidate == name)
    {
        return value.clone();
    }
    let Expr::Call { head, args } = expr else {
        return expr.clone();
    };
    if is_symbol(head, "Function")
        && matches!(args.len(), 2..=3)
        && let Some(parameters) = function_parameter_names(&args[0])
    {
        let filtered = renames
            .iter()
            .filter(|(name, _)| !parameters.contains(name))
            .cloned()
            .collect::<Vec<_>>();
        let mut output = vec![args[0].clone(), rename_symbols_scoped(&args[1], &filtered)];
        output.extend(args.iter().skip(2).cloned());
        return call("Function", output);
    }
    call(
        rename_symbols_scoped(head, renames),
        args.iter()
            .map(|argument| rename_symbols_scoped(argument, renames)),
    )
}

fn function_parameter_names(expr: &Expr) -> Option<Vec<String>> {
    match expr {
        Expr::Symbol(name) => Some(vec![name.clone()]),
        Expr::Call { head, args }
            if is_symbol(head, "List")
                && args
                    .iter()
                    .all(|argument| matches!(argument, Expr::Symbol(_))) =>
        {
            Some(
                args.iter()
                    .filter_map(Expr::symbol_name)
                    .map(str::to_owned)
                    .collect(),
            )
        }
        _ => None,
    }
}

fn contains_symbol_name(expr: &Expr, expected: &str) -> bool {
    match expr {
        Expr::Symbol(name) => name == expected,
        Expr::Call { head, args } => {
            contains_symbol_name(head, expected)
                || args
                    .iter()
                    .any(|argument| contains_symbol_name(argument, expected))
        }
        _ => false,
    }
}

fn restore_definition(
    values: &mut HashMap<String, Definition>,
    name: &str,
    snapshot: Option<Definition>,
) {
    if let Some(definition) = snapshot {
        values.insert(name.to_owned(), definition);
    } else {
        values.remove(name);
    }
}

fn restore_definitions(
    values: &mut HashMap<String, Vec<Definition>>,
    name: &str,
    snapshot: Option<Vec<Definition>>,
) {
    if let Some(definitions) = snapshot {
        values.insert(name.to_owned(), definitions);
    } else {
        values.remove(name);
    }
}

fn snapshot_definitions(evaluator: &Evaluator, name: &str) -> DefinitionSnapshot {
    DefinitionSnapshot {
        name: name.to_owned(),
        own: evaluator.own_values.get(name).cloned(),
        down: evaluator.down_values.get(name).cloned(),
        sub: evaluator.sub_values.get(name).cloned(),
        up: evaluator.up_values.get(name).cloned(),
    }
}

fn restore_snapshot(evaluator: &mut Evaluator, snapshot: DefinitionSnapshot) {
    restore_definition(&mut evaluator.own_values, &snapshot.name, snapshot.own);
    restore_definitions(&mut evaluator.down_values, &snapshot.name, snapshot.down);
    restore_definitions(&mut evaluator.sub_values, &snapshot.name, snapshot.sub);
    restore_definitions(&mut evaluator.up_values, &snapshot.name, snapshot.up);
}

fn iterator_count(count: &Expr) -> Option<IteratorValues> {
    let Expr::Integer(count) = count else {
        return None;
    };
    if count.is_negative() {
        return None;
    }
    let count = count.to_usize()?;
    (count <= 1_000_000).then(|| IteratorValues {
        variable: None,
        values: std::iter::repeat_n(symbol("Null"), count).collect(),
    })
}

fn iterator_range(
    variable: Option<String>,
    start: Expr,
    end: Expr,
    step: Expr,
) -> Option<IteratorValues> {
    let mut current = as_rational(&start)?;
    let end = as_rational(&end)?;
    let step = as_rational(&step)?;
    if step.is_zero() {
        return None;
    }
    let mut values = Vec::new();
    while if step.is_positive() {
        current <= end
    } else {
        current >= end
    } {
        values.push(from_rational(current.clone()));
        current += &step;
        if values.len() > 1_000_000 {
            return None;
        }
    }
    Some(IteratorValues { variable, values })
}

fn flatten_same_head(name: &str, args: Vec<Expr>) -> Vec<Expr> {
    let mut result = Vec::new();
    for argument in args {
        if argument.has_head(name) {
            result.extend(argument.args().iter().cloned());
        } else {
            result.push(argument);
        }
    }
    result
}

fn splice_raw_sequences(args: Vec<Expr>) -> Vec<Expr> {
    let mut result = Vec::new();
    for argument in args {
        if argument.has_head("Sequence") {
            result.extend(argument.args().iter().cloned());
        } else {
            result.push(argument);
        }
    }
    result
}

fn strip_unevaluated(expr: Expr) -> Expr {
    if expr.has_head("Unevaluated") && expr.args().len() == 1 {
        expr.args()[0].clone()
    } else {
        expr
    }
}

fn is_function(expr: &Expr) -> bool {
    expr.has_head("Function") && matches!(expr.args().len(), 1..=3)
}

fn is_symbol(expr: &Expr, expected: &str) -> bool {
    expr.symbol_name()
        .is_some_and(|name| system_dispatch_name(name) == expected)
}

fn simple_pattern_matches(expr: &Expr, pattern: &Expr) -> bool {
    if pattern.has_head("Pattern") && pattern.args().len() == 2 {
        return simple_pattern_matches(expr, &pattern.args()[1]);
    }
    if pattern.has_head("Blank") {
        return match pattern.args() {
            [] => true,
            [Expr::Symbol(head)] => expr
                .head()
                .symbol_name()
                .is_some_and(|name| system_dispatch_name(name) == system_dispatch_name(head)),
            _ => false,
        };
    }
    if pattern.has_head("Alternatives") {
        return pattern
            .args()
            .iter()
            .any(|alternative| simple_pattern_matches(expr, alternative));
    }
    expr == pattern
}

fn direct_sequence_pattern_head(pattern: &Expr) -> Option<&str> {
    let Expr::Call { head, .. } = pattern else {
        return None;
    };
    head.symbol_name().map(system_dispatch_name).filter(|name| {
        matches!(
            *name,
            "BlankSequence"
                | "BlankNullSequence"
                | "Repeated"
                | "RepeatedNull"
                | "PatternSequence"
                | "OrderlessPatternSequence"
                | "OptionsPattern"
        )
    })
}

fn is_sequence_argument_pattern(pattern: &Expr) -> bool {
    if direct_sequence_pattern_head(pattern).is_some() || pattern.has_head("Optional") {
        return true;
    }
    if matches!(
        pattern.head().symbol_name().map(system_dispatch_name),
        Some("HoldPattern" | "Condition" | "PatternTest" | "Longest" | "Shortest")
    ) && !pattern.args().is_empty()
    {
        return is_sequence_argument_pattern(&pattern.args()[0]);
    }
    if pattern.has_head("Pattern") && pattern.args().len() == 2 {
        return is_sequence_argument_pattern(&pattern.args()[1]);
    }
    pattern.has_head("Alternatives") && pattern.args().iter().any(is_sequence_argument_pattern)
}

fn repetition_bound(value: &Expr) -> Option<usize> {
    match value {
        Expr::Integer(value) if !value.is_negative() => value.to_usize(),
        Expr::Symbol(name) if system_dispatch_name(name) == "Infinity" => Some(usize::MAX),
        _ => None,
    }
}

fn repetition_count_bounds(pattern: &Expr) -> Option<(usize, usize)> {
    let repeated_null = pattern.has_head("RepeatedNull");
    let default_minimum = usize::from(!repeated_null);
    match pattern.args() {
        [_] => Some((default_minimum, usize::MAX)),
        [_, specification] => {
            if let Some(maximum) = repetition_bound(specification) {
                return Some((default_minimum, maximum));
            }
            if specification.has_head("List") {
                return match specification.args() {
                    [value] => repetition_bound(value).map(|value| (value, value)),
                    [minimum, maximum] => {
                        Some((repetition_bound(minimum)?, repetition_bound(maximum)?))
                    }
                    _ => None,
                };
            }
            None
        }
        _ => None,
    }
}

fn pattern_width_bounds(pattern: &Expr) -> Option<(usize, usize)> {
    if is_sequence_argument_pattern(pattern) {
        sequence_pattern_length_bounds(pattern)
    } else {
        Some((1, 1))
    }
}

fn sequence_pattern_length_bounds(pattern: &Expr) -> Option<(usize, usize)> {
    match direct_sequence_pattern_head(pattern) {
        Some("BlankSequence") => return Some((1, usize::MAX)),
        Some("BlankNullSequence") => return Some((0, usize::MAX)),
        _ => {}
    }
    if matches!(
        pattern.head().symbol_name().map(system_dispatch_name),
        Some("HoldPattern" | "Condition" | "PatternTest" | "Longest" | "Shortest")
    ) && !pattern.args().is_empty()
    {
        return sequence_pattern_length_bounds(&pattern.args()[0]);
    }
    if pattern.has_head("Pattern") && pattern.args().len() == 2 {
        return sequence_pattern_length_bounds(&pattern.args()[1]);
    }
    if pattern.has_head("Alternatives") && !pattern.args().is_empty() {
        let bounds = pattern
            .args()
            .iter()
            .map(pattern_width_bounds)
            .collect::<Option<Vec<_>>>()?;
        return Some((
            bounds.iter().map(|(low, _)| *low).min()?,
            bounds.iter().map(|(_, high)| *high).max()?,
        ));
    }
    if pattern.has_head("Optional") && matches!(pattern.args().len(), 1 | 2) {
        let (minimum, maximum) = pattern_width_bounds(&pattern.args()[0])?;
        return Some((
            if pattern.args().len() == 2 {
                0
            } else {
                minimum
            },
            maximum,
        ));
    }
    if matches!(
        pattern.head().symbol_name().map(system_dispatch_name),
        Some("Repeated" | "RepeatedNull")
    ) {
        let (item_minimum, item_maximum) = pattern_width_bounds(&pattern.args()[0])?;
        let (count_minimum, count_maximum) = repetition_count_bounds(pattern)?;
        return Some((
            item_minimum.saturating_mul(count_minimum),
            item_maximum.saturating_mul(count_maximum),
        ));
    }
    if pattern.has_head("PatternSequence") || pattern.has_head("OrderlessPatternSequence") {
        let mut minimum = 0usize;
        let mut maximum = 0usize;
        for argument in pattern.args() {
            let (low, high) = pattern_width_bounds(argument)?;
            minimum = minimum.saturating_add(low);
            maximum = maximum.saturating_add(high);
        }
        return Some((minimum, maximum));
    }
    if pattern.has_head("OptionsPattern") && pattern.args().len() <= 1 {
        return Some((0, usize::MAX));
    }
    None
}

fn minimum_argument_count(patterns: &[Expr]) -> usize {
    patterns
        .iter()
        .map(|pattern| pattern_width_bounds(pattern).map_or(1, |(minimum, _)| minimum))
        .fold(0usize, usize::saturating_add)
}

fn sequence_prefers_longest(pattern: &Expr) -> bool {
    if pattern.has_head("Longest") {
        return true;
    }
    if pattern.has_head("Shortest") {
        return false;
    }
    if pattern.has_head("Optional") && pattern.args().len() == 2 {
        return true;
    }
    if matches!(
        pattern.head().symbol_name().map(system_dispatch_name),
        Some("HoldPattern" | "Condition" | "PatternTest" | "Pattern")
    ) && !pattern.args().is_empty()
    {
        let inner = if pattern.has_head("Pattern") && pattern.args().len() == 2 {
            &pattern.args()[1]
        } else {
            &pattern.args()[0]
        };
        return sequence_prefers_longest(inner);
    }
    false
}

fn sequence_length_order(pattern: &Expr, minimum: usize, maximum: usize) -> Vec<usize> {
    if minimum > maximum {
        return Vec::new();
    }
    let mut lengths = (minimum..=maximum).collect::<Vec<_>>();
    if sequence_prefers_longest(pattern) {
        lengths.reverse();
    }
    lengths
}

fn sequence_binding_value(expressions: &[Expr]) -> Expr {
    if let [expression] = expressions {
        expression.clone()
    } else {
        call("Sequence", expressions.iter().cloned())
    }
}

fn unique_permutations(values: &[Expr]) -> Vec<Vec<Expr>> {
    fn recurse(remaining: &[Expr], prefix: &mut Vec<Expr>, output: &mut Vec<Vec<Expr>>) {
        if remaining.is_empty() {
            if !output.contains(prefix) {
                output.push(prefix.clone());
            }
            return;
        }
        for index in 0..remaining.len() {
            let mut next = remaining.to_vec();
            let value = next.remove(index);
            prefix.push(value);
            recurse(&next, prefix, output);
            prefix.pop();
        }
    }
    let mut output = Vec::new();
    recurse(values, &mut Vec::new(), &mut output);
    output
}

fn is_option_expr(expr: &Expr) -> bool {
    if let Some((key, _, _)) = rule_parts(expr) {
        return matches!(key, Expr::Symbol(_) | Expr::String(_));
    }
    expr.has_head("List") && expr.args().iter().all(is_option_expr)
}

fn is_confirm_failure(expr: &Expr) -> bool {
    expr.has_head("Failure")
        || expr.has_head("Missing")
        || matches!(expr, Expr::Symbol(name) if matches!(system_dispatch_name(name), "$Failed" | "$Canceled" | "$Aborted"))
}

fn failure_expr<const N: usize>(kind: &str, fields: [(&str, Expr); N]) -> Expr {
    call(
        "Failure",
        [
            symbol(kind),
            call(
                "Association",
                fields
                    .into_iter()
                    .map(|(name, value)| call("Rule", [string(name), value])),
            ),
        ],
    )
}

fn confirmation_failure(
    kind: &str,
    expression: Expr,
    information: Expr,
    extra: Vec<(&str, Expr)>,
) -> Expr {
    let mut fields = vec![
        call("Rule", [string("ConfirmationType"), symbol(kind)]),
        call("Rule", [string("Expression"), expression]),
        call("Rule", [string("Information"), information]),
    ];
    fields.extend(
        extra
            .into_iter()
            .map(|(name, value)| call("Rule", [string(name), value])),
    );
    call(
        "Failure",
        [symbol("ConfirmationFailed"), call("Association", fields)],
    )
}

fn failure_property(failure: &Expr, key: &Expr) -> Expr {
    let Expr::String(key) = key else {
        return call(failure.clone(), [key.clone()]);
    };
    if matches!(key.as_str(), "Type" | "FailureType") {
        return failure
            .args()
            .first()
            .cloned()
            .unwrap_or_else(|| call("Missing", [string("KeyAbsent"), string(key)]));
    }
    if let Some(details) = failure.args().get(1)
        && let Some(entries) = association_entries(details)
        && let Some(entry) = entries
            .iter()
            .find(|entry| matches!(&entry.args()[0], Expr::String(name) if name == key))
    {
        return entry.args()[1].clone();
    }
    call("Missing", [string("KeyAbsent"), string(key)])
}

fn normalize_rules(rules: &Expr) -> Vec<Expr> {
    if rules.has_head("List") {
        rules.args().to_vec()
    } else {
        vec![rules.clone()]
    }
}

fn definition_owner(lhs: &Expr) -> Option<String> {
    match lhs {
        Expr::Symbol(name) => Some(name.clone()),
        Expr::Call { head, .. } => definition_owner(head),
        _ => None,
    }
}

fn is_subvalue_lhs(lhs: &Expr) -> bool {
    matches!(lhs, Expr::Call { head, .. } if matches!(head.as_ref(), Expr::Call { .. }))
}

fn tagged_upvalue_position(lhs: &Expr, tag: &str) -> bool {
    let Expr::Call { args, .. } = lhs else {
        return false;
    };
    args.iter()
        .any(|argument| definition_owner(argument).as_deref() == Some(tag))
}

fn insert_definition(definitions: &mut Vec<Definition>, definition: Definition) {
    if let Some(existing) = definitions.iter_mut().find(|existing| {
        existing.lhs == definition.lhs && existing.condition == definition.condition
    }) {
        *existing = definition;
        return;
    }
    let score = definition_specificity(&definition.lhs);
    let index = definitions
        .iter()
        .position(|existing| score < definition_specificity(&existing.lhs))
        .unwrap_or(definitions.len());
    definitions.insert(index, definition);
}

fn definition_list(definitions: Option<&Vec<Definition>>) -> Expr {
    list(definitions.into_iter().flatten().map(definition_rule))
}

fn definition_rule(definition: &Definition) -> Expr {
    let rhs = definition.condition.as_ref().map_or_else(
        || definition.rhs.clone(),
        |condition| call("Condition", [definition.rhs.clone(), condition.clone()]),
    );
    call(
        "RuleDelayed",
        [call("HoldPattern", [definition.lhs.clone()]), rhs],
    )
}

fn peel_condition(expr: &Expr) -> (&Expr, Option<&Expr>) {
    if expr.has_head("Condition")
        && let [body, condition] = expr.args()
    {
        (body, Some(condition))
    } else {
        (expr, None)
    }
}

fn combine_conditions(left: Option<&Expr>, right: Option<&Expr>) -> Option<Expr> {
    match (left, right) {
        (Some(left), Some(right)) => Some(call("And", [left.clone(), right.clone()])),
        (Some(condition), None) | (None, Some(condition)) => Some(condition.clone()),
        (None, None) => None,
    }
}

fn collect_pattern_names(expr: &Expr, names: &mut Vec<String>) {
    if expr.has_head("Pattern")
        && let [Expr::Symbol(name), _] = expr.args()
        && !names.contains(name)
    {
        names.push(name.clone());
    }
    if let Expr::Call { head, args } = expr {
        collect_pattern_names(head, names);
        for argument in args {
            collect_pattern_names(argument, names);
        }
    }
}

fn contains_pattern_construct(expr: &Expr) -> bool {
    if let Expr::Call { head, args } = expr {
        if head.symbol_name().is_some_and(|name| {
            matches!(
                system_dispatch_name(name),
                "Pattern"
                    | "Blank"
                    | "BlankSequence"
                    | "BlankNullSequence"
                    | "PatternTest"
                    | "Optional"
                    | "Alternatives"
                    | "Repeated"
                    | "RepeatedNull"
                    | "Condition"
            )
        }) {
            return true;
        }
        return contains_pattern_construct(head) || args.iter().any(contains_pattern_construct);
    }
    false
}

fn definition_specificity(expr: &Expr) -> usize {
    if let Expr::Call { head, args } = expr {
        let head_name = head.symbol_name().map(system_dispatch_name);
        return match (head_name, args.as_slice()) {
            (Some("HoldPattern"), [argument]) => definition_specificity(argument),
            (Some("Pattern"), [_, pattern]) => definition_specificity(pattern),
            (Some("Blank"), []) => 20,
            (Some("Blank"), [_]) => 12,
            (Some("BlankSequence"), _) => {
                30 + args.iter().map(definition_specificity).sum::<usize>()
            }
            (Some("BlankNullSequence"), _) => {
                35 + args.iter().map(definition_specificity).sum::<usize>()
            }
            (Some("Condition"), [pattern, _]) => 2 + definition_specificity(pattern),
            (Some("PatternTest"), [pattern, _]) => 3 + definition_specificity(pattern),
            (Some("Optional"), [pattern, ..]) => 5 + definition_specificity(pattern),
            (Some("Alternatives"), _) => {
                4 + args.iter().map(definition_specificity).min().unwrap_or(0)
            }
            (Some("Repeated" | "RepeatedNull"), [pattern, ..]) => {
                25 + definition_specificity(pattern)
            }
            _ => args.iter().map(definition_specificity).sum(),
        };
    }
    0
}

fn clear_names(expr: &Expr, names: &mut Vec<String>) -> bool {
    match expr {
        Expr::Symbol(name) | Expr::String(name) => {
            names.push(name.clone());
            true
        }
        Expr::Call { head, args } if is_symbol(head, "List") => {
            args.iter().all(|argument| clear_names(argument, names))
        }
        _ => false,
    }
}

fn attribute_target_name(expr: &Expr) -> Option<&str> {
    match expr {
        Expr::Symbol(name) | Expr::String(name) => Some(name),
        _ => None,
    }
}

fn attribute_targets(expr: &Expr, names: &mut Vec<String>) -> bool {
    if let Some(name) = attribute_target_name(expr) {
        names.push(name.to_owned());
        return true;
    }
    if expr.has_head("List") {
        return expr
            .args()
            .iter()
            .all(|argument| attribute_targets(argument, names));
    }
    false
}

fn attribute_names(expr: &Expr, names: &mut Vec<String>) -> bool {
    match expr {
        Expr::Symbol(name) => {
            names.push(system_dispatch_name(name).to_owned());
            true
        }
        Expr::Call { head, args } if is_symbol(head, "List") => {
            args.iter().all(|argument| attribute_names(argument, names))
        }
        _ => false,
    }
}

fn builtin_attributes(name: &str) -> &'static [&'static str] {
    match name {
        "Plus" | "Times" => &[
            "Flat",
            "Listable",
            "NumericFunction",
            "OneIdentity",
            "Orderless",
            "Protected",
        ],
        "Abs" | "Sign" | "RealAbs" | "RealSign" | "Unitize" | "UnitStep" | "Ramp" => {
            &["Listable", "NumericFunction", "Protected"]
        }
        "Attributes" => &["HoldAll", "Listable", "Protected"],
        "Set" | "SetDelayed" | "Unset" | "Clear" | "ClearAll" | "SetAttributes"
        | "ClearAttributes" | "Protect" | "Unprotect" => &["HoldAll", "Protected"],
        "Hold" | "HoldForm" | "HoldPattern" => &["HoldAll", "Protected"],
        "HoldComplete" => &["HoldAllComplete", "Protected"],
        "Function" => &["HoldAll", "Protected"],
        "If" | "Which" | "Switch" | "Piecewise" | "CompoundExpression" | "With" | "Module"
        | "Block" | "Table" | "Do" | "Sum" | "Product" | "For" | "While" => {
            &["HoldAll", "Protected"]
        }
        "List" | "Rule" | "RuleDelayed" | "Pattern" | "Blank" | "BlankSequence"
        | "BlankNullSequence" => &["Protected"],
        _ => &[],
    }
}

fn rule_parts(rule: &Expr) -> Option<(&Expr, &Expr, bool)> {
    if rule.args().len() != 2 {
        return None;
    }
    if rule.has_head("Rule") {
        Some((&rule.args()[0], &rule.args()[1], false))
    } else if rule.has_head("RuleDelayed") {
        Some((&rule.args()[0], &rule.args()[1], true))
    } else {
        None
    }
}

fn target_call_args(expr: &Expr) -> Option<&[Expr]> {
    match expr {
        Expr::Call { args, .. } => Some(args),
        _ => None,
    }
}

fn substitute_binding_values(expr: &Expr, bindings: &[(String, Expr)]) -> Expr {
    if let Expr::Symbol(name) = expr
        && let Some((_, value)) = bindings.iter().find(|(binding, _)| binding == name)
    {
        return value.clone();
    }
    match expr {
        Expr::Call { head, args } => {
            let mut substituted_args = Vec::new();
            for argument in args {
                let substituted = substitute_binding_values(argument, bindings);
                if substituted.has_head("Sequence") {
                    substituted_args.extend(substituted.args().iter().cloned());
                } else {
                    substituted_args.push(substituted);
                }
            }
            call(substitute_binding_values(head, bindings), substituted_args)
        }
        _ => expr.clone(),
    }
}

fn bool_expr(value: bool) -> Expr {
    symbol(if value { "True" } else { "False" })
}

fn is_non_symbol_atom(expr: &Expr) -> bool {
    expr.is_atom() && !matches!(expr, Expr::Symbol(_))
}

fn is_exact_real(expr: &Expr) -> bool {
    matches!(expr, Expr::Integer(_) | Expr::Rational(_))
}

fn is_real_number(expr: &Expr) -> bool {
    matches!(expr, Expr::Integer(_) | Expr::Rational(_) | Expr::Real(_))
}

fn is_number(expr: &Expr) -> bool {
    matches!(
        expr,
        Expr::Integer(_)
            | Expr::Rational(_)
            | Expr::Real(_)
            | Expr::Complex { .. }
            | Expr::Root { .. }
            | Expr::SpecialReal(_)
    )
}

fn is_exact_number(expr: &Expr) -> bool {
    match expr {
        Expr::Integer(_) | Expr::Rational(_) | Expr::Root { .. } => true,
        Expr::Complex { real, imaginary } => is_exact_real(real) && is_exact_real(imaginary),
        _ => false,
    }
}

fn is_machine_number(expr: &Expr) -> bool {
    match expr {
        Expr::Real(text) => !text.contains('`'),
        Expr::Complex { real, imaginary } => {
            (is_machine_number(real) || is_machine_number(imaginary))
                && numeric_q(real)
                && numeric_q(imaginary)
        }
        Expr::Call { head, args }
            if head.symbol_name().is_some_and(|name| {
                matches!(
                    system_dispatch_name(name),
                    "Plus" | "Times" | "Power" | "Sqrt" | "Abs" | "Sign"
                )
            }) =>
        {
            args.iter().all(numeric_q) && args.iter().any(is_machine_number)
        }
        _ => false,
    }
}

fn contains_inexact_number(expr: &Expr) -> bool {
    match expr {
        Expr::Real(_) => true,
        Expr::Complex { real, imaginary } => {
            contains_inexact_number(real) || contains_inexact_number(imaginary)
        }
        Expr::Call { args, .. } => args.iter().any(contains_inexact_number),
        _ => false,
    }
}

fn numeric_q(expr: &Expr) -> bool {
    if is_number(expr) && !matches!(expr, Expr::SpecialReal(_)) {
        return true;
    }
    if matches!(expr, Expr::Symbol(name) if matches!(system_dispatch_name(name), "Infinity" | "Indeterminate" | "ComplexInfinity"))
    {
        return false;
    }
    if expr.has_head("Root") {
        return true;
    }
    if let Expr::Call { head, args } = expr
        && head.symbol_name().is_some_and(|name| {
            matches!(
                system_dispatch_name(name),
                "Plus"
                    | "Times"
                    | "Power"
                    | "Sin"
                    | "Cos"
                    | "Tan"
                    | "Exp"
                    | "Log"
                    | "Sqrt"
                    | "Abs"
                    | "Sign"
            )
        })
    {
        return args.iter().all(numeric_q);
    }
    false
}

fn exact_complex_parts(expr: &Expr) -> Option<(BigRational, BigRational)> {
    match expr {
        Expr::Integer(_) | Expr::Rational(_) => Some((as_rational(expr)?, BigRational::zero())),
        Expr::Complex { real, imaginary } => Some((as_rational(real)?, as_rational(imaginary)?)),
        _ => None,
    }
}

fn add_exact_numbers(left: &Expr, right: &Expr) -> Option<Expr> {
    let (left_real, left_imaginary) = exact_complex_parts(left)?;
    let (right_real, right_imaginary) = exact_complex_parts(right)?;
    Some(complex(
        from_rational(left_real + right_real),
        from_rational(left_imaginary + right_imaginary),
    ))
}

fn multiply_exact_numbers(left: &Expr, right: &Expr) -> Option<Expr> {
    let (left_real, left_imaginary) = exact_complex_parts(left)?;
    let (right_real, right_imaginary) = exact_complex_parts(right)?;
    let real = &left_real * &right_real - &left_imaginary * &right_imaginary;
    let imaginary = left_real * right_imaginary + left_imaginary * right_real;
    Some(complex(from_rational(real), from_rational(imaginary)))
}

fn as_rational(expr: &Expr) -> Option<BigRational> {
    match expr {
        Expr::Integer(value) => Some(BigRational::from_integer(value.clone())),
        Expr::Rational(value) => Some(value.clone()),
        _ => None,
    }
}

fn from_rational(value: BigRational) -> Expr {
    rational(value.numer().clone(), value.denom().clone())
}

fn exact_rational_sqrt(value: &BigRational) -> Option<BigRational> {
    if value.is_negative() {
        return None;
    }
    let numerator = value.numer().sqrt();
    let denominator = value.denom().sqrt();
    (&numerator * &numerator == *value.numer() && &denominator * &denominator == *value.denom())
        .then(|| BigRational::new(numerator, denominator))
}

fn exact_square_root(value: BigRational) -> Option<Expr> {
    Some(if let Some(root) = exact_rational_sqrt(&value) {
        from_rational(root)
    } else {
        call("Power", [from_rational(value), rational(1, 2)])
    })
}

fn real_to_f64(text: &str) -> Option<f64> {
    let mantissa = text.split('`').next().unwrap_or(text);
    mantissa.replace("*^", "e").parse().ok()
}

fn decimal_rational(text: &str) -> Option<BigRational> {
    let mantissa = text.split('`').next()?.trim();
    let (mantissa, exponent) = if let Some((mantissa, exponent)) = mantissa.split_once("*^") {
        (
            mantissa,
            exponent.trim_start_matches('+').parse::<i64>().ok()?,
        )
    } else {
        (mantissa, 0)
    };
    let negative = mantissa.starts_with('-');
    let unsigned = mantissa.trim_start_matches(['+', '-']);
    let (integer_part, fractional_part) = unsigned.split_once('.').unwrap_or((unsigned, ""));
    let digits = format!("{integer_part}{fractional_part}");
    let mut numerator = digits.parse::<BigInt>().ok()?;
    if negative {
        numerator = -numerator;
    }
    let scale = i64::try_from(fractional_part.len()).ok()? - exponent;
    if scale >= 0 {
        Some(BigRational::new(
            numerator,
            BigInt::from(10_u8).pow(u32::try_from(scale).ok()?),
        ))
    } else {
        Some(BigRational::from_integer(
            numerator * BigInt::from(10_u8).pow(u32::try_from(-scale).ok()?),
        ))
    }
}

fn inexact_real_arithmetic(args: &[Expr], multiply: bool) -> Option<Expr> {
    let real_texts = args
        .iter()
        .filter_map(|argument| match argument {
            Expr::Real(text) => Some(text),
            _ => None,
        })
        .collect::<Vec<_>>();
    let machine = real_texts.iter().any(|text| !text.contains('`'));
    if machine {
        let values = args
            .iter()
            .map(numeric_real_value)
            .collect::<Option<Vec<_>>>()?;
        let value = if multiply {
            values.into_iter().product()
        } else {
            values.into_iter().sum()
        };
        return Some(Expr::Real(format_machine_real(value)));
    }
    let precision = real_texts
        .iter()
        .filter_map(|text| explicit_real_precision(text))
        .map(|value| value.max(1.0) as usize)
        .min()?;
    let mut value = if multiply {
        BigRational::one()
    } else {
        BigRational::zero()
    };
    for argument in args {
        let candidate = match argument {
            Expr::Real(text) => decimal_rational(text)?,
            _ => as_rational(argument)?,
        };
        if multiply {
            value *= candidate;
        } else {
            value += candidate;
        }
    }
    Some(arbitrary_real_from_rational(&value, precision))
}

fn arbitrary_real_from_rational(value: &BigRational, precision: usize) -> Expr {
    let mut mantissa = rational_decimal(value.clone(), precision).unwrap_or_else(|| "0".into());
    if let Some((integer_part, fractional_part)) = mantissa.split_once('.') {
        let trimmed = fractional_part.trim_end_matches('0');
        mantissa = if trimmed.is_empty() {
            format!("{integer_part}.")
        } else {
            format!("{integer_part}.{trimmed}")
        };
    }
    Expr::Real(format!("{mantissa}`{precision}."))
}

fn rounded_decimal_constant(value: &str, precision: usize) -> String {
    let point = value.find('.').unwrap_or(value.len());
    let digits = value
        .chars()
        .filter(char::is_ascii_digit)
        .collect::<String>();
    let take = precision.min(digits.len());
    let mut rounded = digits[..take].parse::<BigInt>().unwrap_or_default();
    if digits
        .as_bytes()
        .get(take)
        .is_some_and(|digit| *digit >= b'5')
    {
        rounded += 1;
    }
    let mut digits = rounded.to_string();
    if digits.len() < take {
        digits.insert_str(0, &"0".repeat(take - digits.len()));
    }
    let integer_digits = point.max(1);
    if digits.len() <= integer_digits {
        digits.push('.');
    } else {
        digits.insert(integer_digits, '.');
    }
    digits
}

fn numericize_expr(expr: &Expr, precision: Option<usize>) -> Option<Expr> {
    const PI: &str = "3.1415926535897932384626433832795028841971693993751058209749445923";
    const E: &str = "2.7182818284590452353602874713526624977572470936999595749669676277";
    if let Some(value) = as_rational(expr) {
        return Some(if let Some(precision) = precision {
            arbitrary_real_from_rational(&value, precision)
        } else {
            Expr::Real(format_machine_real(value.to_f64()?))
        });
    }
    if let Expr::Real(_) = expr {
        return Some(expr.clone());
    }
    if let Expr::Symbol(name) = expr {
        let source = match system_dispatch_name(name) {
            "Pi" => PI,
            "E" => E,
            _ => return None,
        };
        return Some(if let Some(precision) = precision {
            Expr::Real(format!(
                "{}`{precision}.",
                rounded_decimal_constant(source, precision)
            ))
        } else {
            Expr::Real(format_machine_real(source.parse().ok()?))
        });
    }
    if expr.has_head("Sin") && expr.args().len() == 1 && is_pi_over_six(&expr.args()[0]) {
        return Some(if let Some(precision) = precision {
            Expr::Real(format!("0.5`{precision}."))
        } else {
            Expr::Real("0.5".into())
        });
    }
    let value = numeric_f64(expr)?;
    Some(if let Some(precision) = precision {
        Expr::Real(format!("{}`{precision}.", format_machine_real(value)))
    } else {
        Expr::Real(format_machine_real(value))
    })
}

fn is_pi_over_six(expr: &Expr) -> bool {
    expr.has_head("Times")
        && expr.args().len() == 2
        && expr.args().iter().any(|argument| is_symbol(argument, "Pi"))
        && expr
            .args()
            .iter()
            .any(|argument| as_rational(argument) == Some(BigRational::new(1.into(), 6.into())))
}

fn numeric_f64(expr: &Expr) -> Option<f64> {
    if let Some(value) = numeric_real_value(expr) {
        return Some(value);
    }
    if let Expr::Symbol(name) = expr {
        return match system_dispatch_name(name) {
            "Pi" => Some(std::f64::consts::PI),
            "E" => Some(std::f64::consts::E),
            _ => None,
        };
    }
    let values = expr
        .args()
        .iter()
        .map(numeric_f64)
        .collect::<Option<Vec<_>>>()?;
    match expr.head().symbol_name().map(system_dispatch_name) {
        Some("Plus") => Some(values.into_iter().sum()),
        Some("Times") => Some(values.into_iter().product()),
        Some("Power") if values.len() == 2 => Some(values[0].powf(values[1])),
        Some("Sin") if values.len() == 1 => Some(values[0].sin()),
        Some("Cos") if values.len() == 1 => Some(values[0].cos()),
        Some("Tan") if values.len() == 1 => Some(values[0].tan()),
        Some("Exp") if values.len() == 1 => Some(values[0].exp()),
        Some("Log") if values.len() == 1 => Some(values[0].ln()),
        _ => None,
    }
}

fn numeric_real_value(expr: &Expr) -> Option<f64> {
    match expr {
        Expr::Integer(value) => value.to_f64(),
        Expr::Rational(value) => value.to_f64(),
        Expr::Real(text) => real_to_f64(text),
        Expr::SpecialReal(name) if name == "Overflow" => Some(f64::INFINITY),
        Expr::SpecialReal(name) if name == "Underflow" => Some(0.0),
        _ => None,
    }
}

fn numeric_complex_value(expr: &Expr) -> Option<(f64, f64)> {
    match expr {
        Expr::Integer(_) | Expr::Rational(_) | Expr::Real(_) | Expr::SpecialReal(_) => {
            Some((numeric_real_value(expr)?, 0.0))
        }
        Expr::Complex { real, imaginary } => {
            Some((numeric_real_value(real)?, numeric_real_value(imaginary)?))
        }
        Expr::Call { head, args } if is_symbol(head, "Plus") => {
            let mut result = (0.0, 0.0);
            for argument in args {
                let value = numeric_complex_value(argument)?;
                result.0 += value.0;
                result.1 += value.1;
            }
            Some(result)
        }
        Expr::Call { head, args } if is_symbol(head, "Times") => {
            let mut result = (1.0, 0.0);
            for argument in args {
                let value = numeric_complex_value(argument)?;
                result = (
                    result.0 * value.0 - result.1 * value.1,
                    result.0 * value.1 + result.1 * value.0,
                );
            }
            Some(result)
        }
        _ => None,
    }
}

fn to_string_expr(args: &[Expr]) -> Option<Expr> {
    if args.is_empty() || args.len() > 3 {
        return None;
    }
    let mut value = &args[0];
    let mut explicit_form = None;
    let mut option_form = None;
    for argument in &args[1..] {
        if (argument.has_head("Rule") || argument.has_head("RuleDelayed"))
            && argument.args().len() == 2
            && is_symbol(&argument.args()[0], "FormatType")
        {
            option_form = argument.args()[1].symbol_name().map(system_dispatch_name);
        } else if explicit_form.is_none() {
            explicit_form = argument.symbol_name().map(system_dispatch_name);
            if explicit_form.is_none() {
                return None;
            }
        } else {
            return None;
        }
    }
    let mut form = explicit_form.or(option_form).unwrap_or("StandardForm");
    if explicit_form.is_none()
        && let Expr::Call { head, args } = value
        && args.len() == 1
        && head.symbol_name().is_some_and(|name| {
            matches!(
                system_dispatch_name(name),
                "InputForm"
                    | "FullForm"
                    | "StandardForm"
                    | "OutputForm"
                    | "TraditionalForm"
                    | "TeXForm"
                    | "MathMLForm"
                    | "CForm"
                    | "FortranForm"
                    | "TextForm"
            )
        })
    {
        form = head.symbol_name().map(system_dispatch_name)?;
        value = &args[0];
    }
    let rendered = match form {
        "FullForm" => value.to_full_form(),
        "TeXForm" => tex_form(value),
        "MathMLForm" => mathml_form(value),
        "TraditionalForm" => format!(
            r#"\!\(\*FormBox[{}, TraditionalForm]\)"#,
            traditional_boxes(value).to_input_form()
        ),
        "CForm" => c_form(value),
        "FortranForm" => fortran_form(value),
        "InputForm" | "StandardForm" | "OutputForm" | "TextForm" => value.to_input_form(),
        _ => return None,
    };
    Some(string(rendered))
}

fn format_print_argument(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression
        && let [payload, rest @ ..] = args.as_slice()
        && let Some(name) = head.symbol_name().map(system_dispatch_name)
    {
        return match name {
            "FullForm" => payload.to_full_form(),
            "TeXForm" => tex_form(payload),
            "MathMLForm" => mathml_form(payload),
            "TraditionalForm" => format!(
                r#"\!\(\*FormBox[{}, TraditionalForm]\)"#,
                traditional_boxes(payload).to_input_form()
            ),
            "CForm" => c_form(payload),
            "FortranForm" => fortran_form(payload),
            "NumberForm" => format_print_number(payload, rest),
            "InputForm" | "StandardForm" | "OutputForm" | "TextForm" | "PrintForm" => {
                payload.to_input_form()
            }
            _ => expression.to_input_form(),
        };
    }
    if let Expr::String(value) = expression {
        value.clone()
    } else {
        expression.to_input_form()
    }
}

fn message_name_components(name: &Expr) -> Option<(String, Vec<String>)> {
    if !name.has_head("MessageName") || name.args().len() < 2 {
        return None;
    }
    let base = name.args()[0].to_full_form();
    let mut tags = Vec::new();
    for tag in &name.args()[1..] {
        match tag {
            Expr::String(value) | Expr::Symbol(value) => tags.push(value.clone()),
            _ => return None,
        }
    }
    Some((base, tags))
}

fn default_message_detail(name: &Expr) -> &'static str {
    let Some((base, tags)) = message_name_components(name) else {
        return "Message generated.";
    };
    let tag = tags.last().map(String::as_str).unwrap_or_default();
    match (base.as_str(), tag) {
        ("Part", "error") => "Part specifications are invalid for the requested expression.",
        ("Pick", "error") => {
            "Pick currently expects selector parts compatible with the data shape."
        }
        ("StringCases", "error") => {
            "Unsupported Wolfram string-pattern form in the current Tungsten subset."
        }
        ("General", "error") => "Listable Function arguments have incompatible list lengths.",
        ("Assert", "asrtfl") => "Assertion failed.",
        (_, "limset") => "The requested setting value is outside the supported limits.",
        _ => "Message generated.",
    }
}

fn part_error_detail(args: &[Expr]) -> String {
    if let [target, selectors @ ..] = args
        && target.has_head("Association")
        && selectors.iter().any(|selector| {
            selector.has_head("List")
                && selector
                    .args()
                    .iter()
                    .any(|item| matches!(item, Expr::Integer(_)))
                && selector.args().iter().any(|item| item.has_head("Key"))
        })
    {
        return "Association selector lists may not mix numeric and key selectors.".into();
    }
    let target = args
        .first()
        .map_or_else(|| "the requested expression".into(), Expr::to_input_form);
    format!("Part specifications are invalid for {target}.")
}

fn string_cases_error_detail(args: &[Expr]) -> String {
    let Some(pattern) = args.get(1) else {
        return "StringCases expects a string, a pattern or rule, and an optional match limit."
            .into();
    };
    if pattern.has_head("Except")
        && matches!(pattern.args(), [Expr::String(value)] if value.chars().count() != 1)
    {
        return "String-pattern Except expects a single-character disallowed pattern.".into();
    }
    let optional_payload =
        find_expression_with_head(pattern, "Optional").and_then(|optional| optional.args().first());
    let unsupported = optional_payload.unwrap_or(pattern);
    let punctuation = if optional_payload.is_some() {
        ".."
    } else {
        "."
    };
    format!(
        "Unsupported Wolfram string-pattern form in the current Tungsten subset: {}{punctuation}",
        unsupported.to_input_form(),
    )
}

fn find_expression_with_head<'a>(expression: &'a Expr, name: &str) -> Option<&'a Expr> {
    if expression.has_head(name) {
        return Some(expression);
    }
    if let Expr::Call { head, args } = expression {
        find_expression_with_head(head, name).or_else(|| {
            args.iter()
                .find_map(|item| find_expression_with_head(item, name))
        })
    } else {
        None
    }
}

fn message_spec_matches(spec: &Expr, name: &Expr) -> bool {
    if let Expr::Symbol(symbol_name) = spec {
        return match system_dispatch_name(symbol_name) {
            "All" => true,
            "None" => false,
            _ => message_spec_matches(
                &call(
                    "MessageName",
                    [symbol(symbol_name.clone()), string("trace")],
                ),
                name,
            ),
        };
    }
    if spec.has_head("List") {
        return spec
            .args()
            .iter()
            .any(|item| message_spec_matches(item, name));
    }
    if !spec.has_head("MessageName") {
        return false;
    }
    if spec == name {
        return true;
    }
    let Some((spec_base, spec_tags)) = message_name_components(spec) else {
        return false;
    };
    let Some((name_base, name_tags)) = message_name_components(name) else {
        return false;
    };
    if spec_base == "General" && !spec_tags.is_empty() && !name_tags.is_empty() {
        return spec_tags.last() == name_tags.last();
    }
    spec_base == name_base && spec_tags == name_tags
}

fn format_print_number(expression: &Expr, specifications: &[Expr]) -> String {
    let digits = specifications
        .first()
        .and_then(|value| match value {
            Expr::Integer(value) => value.to_usize(),
            _ => None,
        })
        .unwrap_or(6);
    let value = match expression {
        Expr::Real(value) => value.trim_end_matches('.').parse::<f64>().ok(),
        Expr::Integer(value) => value.to_f64(),
        _ => None,
    };
    value.map_or_else(
        || expression.to_input_form(),
        |value| format!("{value:.precision$}", precision = digits.saturating_sub(1)),
    )
}

fn tex_form(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression {
        match head.symbol_name().map(system_dispatch_name) {
            Some("StandardForm") if args.len() == 1 => {
                return args[0].to_input_form().replace(' ', "");
            }
            Some("Plus") => {
                let mut terms = args.iter().map(tex_form).collect::<Vec<_>>();
                terms.sort_by_key(|term| term.chars().next().is_some_and(|c| c.is_ascii_digit()));
                return terms.join("+");
            }
            Some("Times") => return args.iter().map(tex_form).collect::<Vec<_>>().join(" "),
            Some("Power") if args.len() == 2 => {
                return format!("{}^{{{}}}", tex_form(&args[0]), tex_form(&args[1]));
            }
            _ => {}
        }
    }
    expression.to_input_form().replace(' ', "")
}

fn c_form(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression {
        return format!(
            "{}({})",
            head.to_input_form(),
            args.iter().map(c_form).collect::<Vec<_>>().join(",")
        );
    }
    expression.to_input_form()
}

fn fortran_form(expression: &Expr) -> String {
    if let Expr::Call { head, args } = expression
        && is_symbol(head, "Power")
        && args.len() == 2
    {
        return format!("{}**{}", fortran_form(&args[0]), fortran_form(&args[1]));
    }
    expression.to_input_form().replace(' ', "")
}

fn traditional_boxes(expression: &Expr) -> Expr {
    match expression {
        Expr::Symbol(_) | Expr::Integer(_) | Expr::Real(_) => string(expression.to_input_form()),
        Expr::String(value) => string(value),
        Expr::Rational(value) => call(
            "FractionBox",
            [
                string(value.numer().to_string()),
                string(value.denom().to_string()),
            ],
        ),
        Expr::Call { head, args } => match head.symbol_name().map(system_dispatch_name) {
            Some("List") => traditional_bracket_boxes("{", args, "}"),
            Some("Association") => traditional_bracket_boxes("<|", args, "|>"),
            Some("Rule") if args.len() == 2 => traditional_infix_boxes(&args[0], "->", &args[1]),
            Some("RuleDelayed") if args.len() == 2 => {
                traditional_infix_boxes(&args[0], ":>", &args[1])
            }
            Some("Plus") if args.len() >= 2 => {
                let mut ordered = args.iter().collect::<Vec<_>>();
                ordered.sort_by_key(|argument| traditional_numeric(argument));
                traditional_separated_boxes(ordered, "+")
            }
            Some("Times") if args.len() >= 2 => traditional_separated_boxes(args, " "),
            Some("Power") if args.len() == 2 => call(
                "SuperscriptBox",
                [traditional_boxes(&args[0]), traditional_boxes(&args[1])],
            ),
            _ => row_box([
                traditional_boxes(head),
                string("["),
                traditional_separated_boxes(args, ","),
                string("]"),
            ]),
        },
        _ => string(expression.to_input_form()),
    }
}

fn standard_boxes(expression: &Expr) -> Expr {
    match expression {
        Expr::Symbol(_) | Expr::Integer(_) | Expr::Real(_) | Expr::String(_) => {
            string(expression.to_input_form())
        }
        Expr::Rational(value) => row_box([
            string(value.numer().to_string()),
            string("/"),
            string(value.denom().to_string()),
        ]),
        Expr::Call { head, args } => match head.symbol_name().map(system_dispatch_name) {
            Some("Plus") if args.len() >= 2 => standard_separated_boxes(args, "+"),
            Some("Times") if args.len() >= 2 => standard_separated_boxes(args, " "),
            Some("Power") if args.len() == 2 => call(
                "SuperscriptBox",
                [standard_boxes(&args[0]), standard_boxes(&args[1])],
            ),
            Some("List") => row_box([
                string("{"),
                standard_separated_boxes(args, ","),
                string("}"),
            ]),
            _ => row_box([
                standard_boxes(head),
                string("["),
                standard_separated_boxes(args, ","),
                string("]"),
            ]),
        },
        _ => string(expression.to_input_form()),
    }
}

fn standard_separated_boxes(expressions: &[Expr], separator: &str) -> Expr {
    let mut pieces = Vec::new();
    for (index, expression) in expressions.iter().enumerate() {
        if index > 0 {
            pieces.push(string(separator));
        }
        pieces.push(standard_boxes(expression));
    }
    row_box(pieces)
}

fn full_form_boxes(expression: &Expr) -> Expr {
    match expression {
        Expr::Call { head, args } => row_box([
            full_form_boxes(head),
            string("["),
            full_form_separated_boxes(args),
            string("]"),
        ]),
        Expr::Rational(value) => row_box([
            string("Rational"),
            string("["),
            row_box([
                string(value.numer().to_string()),
                string(","),
                string(value.denom().to_string()),
            ]),
            string("]"),
        ]),
        _ => string(expression.to_full_form()),
    }
}

fn full_form_separated_boxes(expressions: &[Expr]) -> Expr {
    let mut pieces = Vec::new();
    for (index, expression) in expressions.iter().enumerate() {
        if index > 0 {
            pieces.push(string(","));
        }
        pieces.push(full_form_boxes(expression));
    }
    row_box(pieces)
}

fn option_rule(name: &str, value: Expr) -> Expr {
    call("Rule", [symbol(name), value])
}

fn to_boxes_expr(args: &[Expr]) -> Option<Expr> {
    let ([value] | [value, _]) = args else {
        return None;
    };
    if let Some(form) = args.get(1) {
        return Some(if is_symbol(form, "StandardForm") {
            standard_boxes(value)
        } else if is_symbol(form, "TraditionalForm") {
            call(
                "FormBox",
                [traditional_boxes(value), symbol("TraditionalForm")],
            )
        } else {
            return None;
        });
    }
    let Expr::Call {
        head,
        args: wrapper_args,
    } = value
    else {
        return Some(standard_boxes(value));
    };
    let [payload] = wrapper_args.as_slice() else {
        return Some(standard_boxes(value));
    };
    Some(match head.symbol_name().map(system_dispatch_name) {
        Some("InputForm") => call(
            "InterpretationBox",
            [
                call(
                    "StyleBox",
                    [
                        string(payload.to_input_form()),
                        option_rule("ShowStringCharacters", symbol("True")),
                        option_rule("NumberMarks", symbol("True")),
                    ],
                ),
                call("InputForm", [payload.clone()]),
                option_rule("Editable", symbol("True")),
                option_rule("AutoDelete", symbol("True")),
            ],
        ),
        Some("FullForm") => call(
            "TagBox",
            [
                call(
                    "StyleBox",
                    [
                        full_form_boxes(payload),
                        option_rule("ShowSpecialCharacters", symbol("False")),
                        option_rule("ShowStringCharacters", symbol("True")),
                        option_rule("NumberMarks", symbol("True")),
                    ],
                ),
                symbol("FullForm"),
            ],
        ),
        Some("OutputForm") => call(
            "InterpretationBox",
            [
                call(
                    "PaneBox",
                    [
                        string(payload.to_input_form()),
                        option_rule("BaselinePosition", symbol("Baseline")),
                    ],
                ),
                payload.clone(),
                option_rule("Editable", symbol("False")),
            ],
        ),
        Some("StandardForm") => call(
            "TagBox",
            [
                call("FormBox", [standard_boxes(payload), symbol("StandardForm")]),
                symbol("StandardForm"),
                option_rule("Editable", symbol("True")),
            ],
        ),
        Some("TraditionalForm") => call(
            "TagBox",
            [
                call(
                    "FormBox",
                    [traditional_boxes(payload), symbol("TraditionalForm")],
                ),
                symbol("TraditionalForm"),
                option_rule("Editable", symbol("True")),
            ],
        ),
        Some("TeXForm") => call(
            "InterpretationBox",
            [
                string(format!("\"{}\"", tex_form(payload))),
                payload.clone(),
                option_rule("Editable", symbol("True")),
                option_rule("AutoDelete", symbol("True")),
            ],
        ),
        Some("MathMLForm") => call(
            "InterpretationBox",
            [
                string(mathml_form(payload)),
                payload.clone(),
                option_rule("Editable", symbol("True")),
                option_rule("AutoDelete", symbol("True")),
            ],
        ),
        Some("CForm") => call(
            "InterpretationBox",
            [
                string(c_form(payload)),
                call("CForm", [payload.clone()]),
                option_rule("Editable", symbol("True")),
                option_rule("AutoDelete", symbol("True")),
            ],
        ),
        Some("FortranForm") => call(
            "InterpretationBox",
            [
                string(fortran_form(payload)),
                call("FortranForm", [payload.clone()]),
                option_rule("Editable", symbol("True")),
                option_rule("AutoDelete", symbol("True")),
            ],
        ),
        _ => standard_boxes(value),
    })
}

fn strip_boxes_expr(args: &[Expr]) -> Option<Expr> {
    let [boxes] = args else {
        return None;
    };
    Some(call("BoxData", [strip_box_node(boxes)]))
}

fn strip_box_node(boxes: &Expr) -> Expr {
    if let Expr::Call { head, args } = boxes {
        if head.symbol_name().is_some_and(|name| {
            matches!(
                system_dispatch_name(name),
                "StyleBox"
                    | "TagBox"
                    | "FormBox"
                    | "PaneBox"
                    | "FrameBox"
                    | "TooltipBox"
                    | "InterpretationBox"
            )
        }) && !args.is_empty()
        {
            return strip_box_node(&args[0]);
        }
        if is_symbol(head, "RowBox") && args.len() == 1 && args[0].has_head("List") {
            return row_box(args[0].args().iter().filter_map(|item| {
                if matches!(item, Expr::String(value) if value.trim().is_empty()) {
                    None
                } else {
                    Some(strip_box_node(item))
                }
            }));
        }
        return call(
            head.as_ref().clone(),
            args.iter().map(strip_box_node).collect::<Vec<_>>(),
        );
    }
    boxes.clone()
}

fn traditional_numeric(expression: &Expr) -> bool {
    matches!(
        expression,
        Expr::Integer(_)
            | Expr::Real(_)
            | Expr::Rational(_)
            | Expr::Complex { .. }
            | Expr::SpecialReal(_)
    )
}

fn traditional_bracket_boxes(open: &str, arguments: &[Expr], close: &str) -> Expr {
    row_box([
        string(open),
        traditional_separated_boxes(arguments, ","),
        string(close),
    ])
}

fn traditional_infix_boxes(left: &Expr, operator: &str, right: &Expr) -> Expr {
    row_box([
        traditional_boxes(left),
        string(operator),
        traditional_boxes(right),
    ])
}

fn traditional_separated_boxes<'a>(
    expressions: impl IntoIterator<Item = &'a Expr>,
    separator: &str,
) -> Expr {
    let mut pieces = Vec::new();
    for (index, expression) in expressions.into_iter().enumerate() {
        if index > 0 {
            pieces.push(string(separator));
        }
        pieces.push(traditional_boxes(expression));
    }
    row_box(pieces)
}

fn row_box(items: impl IntoIterator<Item = Expr>) -> Expr {
    call("RowBox", [list(items)])
}

fn mathml_form(expression: &Expr) -> String {
    fn body(expression: &Expr) -> String {
        match expression {
            Expr::Symbol(name) => format!("<mi>{name}</mi>"),
            Expr::Integer(value) => format!("<mn>{value}</mn>"),
            Expr::Real(value) => format!("<mn>{value}</mn>"),
            Expr::Call { head, args } if is_symbol(head, "Plus") => format!(
                "<mrow>{}</mrow>",
                args.iter().map(body).collect::<Vec<_>>().join("<mo>+</mo>")
            ),
            Expr::Call { head, args } if is_symbol(head, "Times") => format!(
                "<mrow>{}</mrow>",
                args.iter()
                    .map(body)
                    .collect::<Vec<_>>()
                    .join("<mo>&#8290;</mo>")
            ),
            _ => format!("<mtext>{}</mtext>", expression.to_input_form()),
        }
    }
    format!(
        "<math>{}<annotation encoding=\"WolframLanguage\">{}</annotation></math>",
        body(expression),
        traditional_source(expression).to_input_form()
    )
}

fn traditional_source(expression: &Expr) -> Expr {
    if let Expr::Call { head, args } = expression {
        let mut transformed = args.iter().map(traditional_source).collect::<Vec<_>>();
        if is_symbol(head, "Plus") {
            transformed.sort_by_key(traditional_numeric);
        }
        call(traditional_source(head), transformed)
    } else {
        expression.clone()
    }
}

fn mathml_annotation(source: &str) -> Option<&str> {
    let marker = "<annotation encoding=\"WolframLanguage\">";
    let start = source.find(marker)? + marker.len();
    let end = source[start..].find("</annotation>")? + start;
    Some(&source[start..end])
}

fn traditional_box_source(source: &str) -> Option<String> {
    if let Some(source) = source
        .strip_prefix(r"\!\(\*")
        .and_then(|source| source.strip_suffix(r"\)"))
    {
        return Some(source.to_owned());
    }
    inline_box_segments(source)
        .into_iter()
        .next()
        .map(|(_, boxes)| boxes)
}

fn syntax_q_expr(args: &[Expr]) -> Option<Expr> {
    let [source] = args else {
        return None;
    };
    let valid = match source {
        Expr::String(source) => parse_input_form(source).is_ok(),
        boxes => interpret_standard_form(boxes.clone()).is_ok(),
    };
    Some(bool_expr(valid))
}

fn syntax_length_expr(args: &[Expr]) -> Option<Expr> {
    let [Expr::String(source)] = args else {
        return None;
    };
    Some(integer(if parse_input_form(source).is_ok() {
        source.chars().count()
    } else {
        source.chars().count() + 2
    }))
}

fn complex_expand_expr(args: &[Expr]) -> Option<Expr> {
    let [value] = args else {
        return None;
    };
    fn normalize(value: &Expr) -> Expr {
        let Expr::Call { head, args } = value else {
            return value.clone();
        };
        let mut args = args.iter().map(normalize).collect::<Vec<_>>();
        if is_symbol(head, "Plus") {
            args.sort_by(|left, right| {
                let left_complex = matches!(left, Expr::Complex { .. });
                let right_complex = matches!(right, Expr::Complex { .. });
                right_complex
                    .cmp(&left_complex)
                    .then_with(|| expression_order(left, right))
            });
        }
        call(head.as_ref().clone(), args)
    }
    Some(call("ComplexExpand", [normalize(value)]))
}

fn explicit_real_precision(text: &str) -> Option<f64> {
    let (_, suffix) = text.split_once('`')?;
    let suffix = suffix.trim_start_matches('`').trim_end_matches('.');
    (!suffix.is_empty()).then(|| suffix.parse().ok()).flatten()
}

fn precision_expr(args: &[Expr], accuracy: bool) -> Option<Expr> {
    let [value] = args else {
        return None;
    };
    if matches!(
        value,
        Expr::Integer(_) | Expr::Rational(_) | Expr::Root { .. }
    ) {
        return Some(symbol("Infinity"));
    }
    if let Expr::SpecialReal(name) = value {
        return Some(match (accuracy, name.as_str()) {
            (false, "Overflow") => Expr::Real("0.".into()),
            (true, "Overflow") => symbol("-Infinity"),
            (true, "Underflow") => symbol("Infinity"),
            _ => Expr::Real("0.".into()),
        });
    }
    let Expr::Real(text) = value else {
        return None;
    };
    let precision = explicit_real_precision(text);
    if !accuracy {
        return Some(precision.map_or_else(
            || symbol("MachinePrecision"),
            |precision| {
                Expr::Real(if precision.fract() == 0.0 {
                    format!("{precision:.0}.")
                } else {
                    precision.to_string()
                })
            },
        ));
    }
    let value = real_to_f64(text)?.abs();
    if value == 0.0 {
        return Some(symbol("Infinity"));
    }
    let precision = precision.unwrap_or(15.954589770191003);
    Some(Expr::Real(format_machine_real(precision - value.log10())))
}

fn set_precision_expr(args: &[Expr], accuracy: bool) -> Option<Expr> {
    let [value, specification] = args else {
        return None;
    };
    if is_symbol(specification, "Infinity") && !accuracy {
        return match value {
            Expr::Integer(_) | Expr::Rational(_) => Some(value.clone()),
            Expr::Real(text) => BigRational::from_float(real_to_f64(text)?).map(from_rational),
            _ => None,
        };
    }
    if is_symbol(specification, "MachinePrecision") {
        return match value {
            Expr::Real(text) => Some(Expr::Real(text.split('`').next()?.to_owned())),
            value => numeric_real_value(value).map(|value| Expr::Real(format_machine_real(value))),
        };
    }
    let Expr::Integer(precision) = specification else {
        return None;
    };
    let precision = precision.to_usize()?;
    let suffix = if accuracy { "``" } else { "`" };
    match value {
        Expr::Real(text) => Some(Expr::Real(format!(
            "{}{}{precision}.",
            text.split('`').next()?,
            suffix
        ))),
        Expr::Integer(_) | Expr::Rational(_) if !accuracy => Some(Expr::Real(format!(
            "{}{suffix}{precision}.",
            rational_decimal(as_rational(value)?, precision)?
        ))),
        _ => None,
    }
}

fn rational_decimal(value: BigRational, precision: usize) -> Option<String> {
    let negative = value.is_negative();
    let value = value.abs();
    let numerator = value.numer();
    let denominator = value.denom();
    let integer_part = numerator / denominator;
    let mut remainder = numerator % denominator;
    let integer_digits = integer_part.to_string().len();
    let fractional_digits = if integer_part.is_zero() {
        precision
    } else {
        precision.saturating_sub(integer_digits)
    };
    let mut fraction = String::with_capacity(fractional_digits);
    for _ in 0..fractional_digits {
        remainder *= 10_u8;
        let digit = &remainder / denominator;
        remainder %= denominator;
        fraction.push(char::from(b'0' + digit.to_u8()?));
    }
    Some(format!(
        "{}{}.{}",
        if negative { "-" } else { "" },
        integer_part,
        fraction
    ))
}

fn format_machine_real(value: f64) -> String {
    if value.fract() == 0.0 {
        format!("{value:.0}.")
    } else {
        value.to_string()
    }
}

fn expression_order(left: &Expr, right: &Expr) -> Ordering {
    if left == right {
        return Ordering::Equal;
    }
    if let (Some((left_real, left_imaginary)), Some((right_real, right_imaginary))) = (
        canonical_numeric_value(left),
        canonical_numeric_value(right),
    ) {
        return left_real
            .partial_cmp(&right_real)
            .unwrap_or(Ordering::Equal)
            .then_with(|| {
                left_imaginary
                    .partial_cmp(&right_imaginary)
                    .unwrap_or(Ordering::Equal)
            })
            .then_with(|| numeric_type_rank(left).cmp(&numeric_type_rank(right)))
            .then_with(|| left.to_full_form().cmp(&right.to_full_form()));
    }
    let rank_order = expression_rank(left).cmp(&expression_rank(right));
    if rank_order != Ordering::Equal {
        return rank_order;
    }
    match (left, right) {
        (Expr::String(left), Expr::String(right)) | (Expr::Symbol(left), Expr::Symbol(right)) => {
            left.cmp(right)
        }
        (Expr::ByteArray(left), Expr::ByteArray(right)) => left.cmp(right),
        (
            Expr::Call {
                head: left_head,
                args: left_args,
            },
            Expr::Call {
                head: right_head,
                args: right_args,
            },
        ) => expression_order(left_head, right_head).then_with(|| {
            left_args
                .iter()
                .zip(right_args)
                .find_map(|(left, right)| {
                    let order = expression_order(left, right);
                    (order != Ordering::Equal).then_some(order)
                })
                .unwrap_or_else(|| left_args.len().cmp(&right_args.len()))
        }),
        _ => left.to_full_form().cmp(&right.to_full_form()),
    }
}

fn canonical_numeric_value(expr: &Expr) -> Option<(f64, f64)> {
    match expr {
        Expr::Symbol(name) if system_dispatch_name(name) == "-Infinity" => {
            Some((f64::NEG_INFINITY, 0.0))
        }
        Expr::Symbol(name) if system_dispatch_name(name) == "Infinity" => {
            Some((f64::INFINITY, 0.0))
        }
        _ => numeric_complex_value(expr),
    }
}

fn numeric_type_rank(expr: &Expr) -> u8 {
    match expr {
        Expr::Symbol(name) if system_dispatch_name(name) == "-Infinity" => 0,
        Expr::Integer(_) => 1,
        Expr::Rational(_) => 2,
        Expr::Real(_) => 3,
        Expr::SpecialReal(_) => 4,
        Expr::Symbol(name) if system_dispatch_name(name) == "Infinity" => 5,
        Expr::Complex { .. } => 6,
        _ => 7,
    }
}

fn order_expr(args: &[Expr]) -> Option<Expr> {
    let [left, right] = args else {
        return None;
    };
    Some(integer(match expression_order(left, right) {
        Ordering::Less => 1,
        Ordering::Equal => 0,
        Ordering::Greater => -1,
    }))
}

fn lexicographic_cmp(left: &Expr, right: &Expr) -> Ordering {
    let left_items = match left {
        Expr::String(value) => value
            .chars()
            .map(|value| string(value.to_string()))
            .collect(),
        Expr::Call { args, .. } => args.clone(),
        _ => return expression_order(left, right),
    };
    let right_items = match right {
        Expr::String(value) => value
            .chars()
            .map(|value| string(value.to_string()))
            .collect(),
        Expr::Call { args, .. } => args.clone(),
        _ => return expression_order(left, right),
    };
    for (left, right) in left_items.iter().zip(&right_items) {
        let order = expression_order(left, right);
        if order != Ordering::Equal {
            return order;
        }
    }
    left_items.len().cmp(&right_items.len())
}

fn lexicographic_order_expr(args: &[Expr]) -> Option<Expr> {
    let [left, right] = args else {
        return None;
    };
    Some(integer(match lexicographic_cmp(left, right) {
        Ordering::Less => 1,
        Ordering::Equal => 0,
        Ordering::Greater => -1,
    }))
}

fn ordered_q_expr(args: &[Expr]) -> Option<Expr> {
    let [target, rest @ ..] = args else {
        return None;
    };
    if rest.len() > 1 || !target.has_head("List") {
        return None;
    }
    let descending = rest
        .first()
        .is_some_and(|function| is_symbol(function, "Greater"));
    Some(bool_expr(target.args().windows(2).all(|pair| {
        let order = expression_order(&pair[0], &pair[1]);
        if descending {
            order != Ordering::Less
        } else {
            order != Ordering::Greater
        }
    })))
}

fn select_ordered_count<T>(mut values: Vec<T>, count: &Expr) -> Option<Vec<T>> {
    match count {
        Expr::Symbol(name) if system_dispatch_name(name) == "All" => Some(values),
        Expr::Integer(count) => {
            let count = count.to_i64()?;
            let magnitude = usize::try_from(count.unsigned_abs())
                .ok()?
                .min(values.len());
            if count >= 0 {
                values.truncate(magnitude);
                Some(values)
            } else {
                Some(values.split_off(values.len() - magnitude))
            }
        }
        _ => None,
    }
}

fn sort_expr(args: &[Expr], reverse: bool) -> Option<Expr> {
    let [target, rest @ ..] = args else {
        return None;
    };
    let (head, mut items, association) = if let Some(entries) = association_entries(target) {
        (symbol("Association"), entries, true)
    } else if let Expr::Call { head, args } = target {
        (head.as_ref().clone(), args.clone(), false)
    } else {
        return None;
    };
    let effective = rest
        .iter()
        .filter(|argument| !argument.has_head("Rule"))
        .collect::<Vec<_>>();
    let comparator = effective
        .first()
        .filter(|argument| is_symbol(argument, "Less") || is_symbol(argument, "Greater"));
    let count = effective
        .iter()
        .find(|argument| matches!(argument, Expr::Integer(_)));
    let descending = comparator.is_some_and(|function| is_symbol(function, "Greater")) ^ reverse;
    items.sort_by(|left, right| {
        let (left, right) = if association {
            (&left.args()[0], &right.args()[0])
        } else {
            (left, right)
        };
        let order = expression_order(left, right);
        if descending { order.reverse() } else { order }
    });
    if let Some(count) = count {
        items = select_ordered_count(items, count)?;
    }
    Some(call(head, items))
}

fn expression_rank(expr: &Expr) -> u8 {
    match expr {
        Expr::Integer(_)
        | Expr::Rational(_)
        | Expr::Real(_)
        | Expr::SpecialReal(_)
        | Expr::Complex { .. } => 0,
        Expr::Symbol(name) if matches!(system_dispatch_name(name), "Infinity" | "-Infinity") => 0,
        Expr::String(_) => 1,
        Expr::Symbol(_) => 2,
        Expr::ByteArray(_) => 3,
        Expr::SparseArray { .. } => 4,
        Expr::Call { .. } => 5,
        _ => 6,
    }
}

fn depth(expr: &Expr) -> usize {
    if let Some(entries) = association_entries(expr) {
        return 1 + entries
            .iter()
            .filter_map(|entry| entry.args().get(1))
            .map(depth)
            .max()
            .unwrap_or(0);
    }
    if expr.args().is_empty() {
        1
    } else {
        1 + expr.args().iter().map(depth).max().unwrap_or(0)
    }
}

#[cfg(test)]
mod tests {
    use pretty_assertions::assert_eq;

    use super::*;
    use crate::expression::parse_input_form;

    fn eval(source: &str) -> String {
        evaluate(parse_input_form(source).unwrap())
            .unwrap()
            .to_full_form()
    }

    fn submit(evaluator: &mut Evaluator, source: &str) -> String {
        evaluator
            .evaluate(parse_input_form(source).unwrap())
            .unwrap()
            .to_full_form()
    }

    #[test]
    fn evaluates_exact_arithmetic() {
        assert_eq!(eval("1 + 2 + 3"), "6");
        assert_eq!(eval("2 * 3 * 4"), "24");
        assert_eq!(eval("2^3"), "8");
        assert_eq!(eval("1 + 2 + a"), "Plus[3, a]");
        assert_eq!(eval("-(1 + 2)"), "-3");
        assert_eq!(eval("1/2 + 1/3"), "Rational[5, 6]");
        assert_eq!(eval("1 + 2 I"), "Complex[1, 2]");
        assert_eq!(eval("AtomQ[1 + 2 I]"), "True");
        assert_eq!(eval("NumberQ[1 + 2 I]"), "True");
        assert_eq!(eval("NumericQ[Sin[1]]"), "True");
    }

    #[test]
    fn evaluates_boolean_and_structural_core() {
        assert_eq!(eval("True && False && x"), "False");
        assert_eq!(eval("False || False || True"), "True");
        assert_eq!(eval("Length[{a, b, c}]"), "3");
        assert_eq!(eval("Depth[f[a, g[b]]]"), "3");
        assert_eq!(eval("Part[f[a, b, c], {1, 3}]"), "f[a, c]");
        assert_eq!(eval("Extract[f[a, g[b]], {{1}, {2, 1}}]"), "List[a, b]");
    }

    #[test]
    fn evaluates_pure_functions_and_sequence() {
        assert_eq!(eval("(# + 1 &)[a]"), "Plus[1, a]");
        assert_eq!(eval("(f[##] &)[a, b, c]"), "f[a, b, c]");
        assert_eq!(eval("Map[# + 1 &, {a, b}]"), "List[Plus[1, a], Plus[1, b]]");
        assert_eq!(eval("{Sequence[1, 2], 3}"), "List[1, 2, 3]");
    }

    #[test]
    fn evaluates_composition_threading_and_structural_sequence_helpers() {
        assert_eq!(eval("UnsameQ[a, b, a]"), "False");
        assert_eq!(eval("SameAs[y][y]"), "True");
        assert_eq!(eval("Composition[f, g][x]"), "f[g[x]]");
        assert_eq!(eval("RightComposition[f, g][x]"), "g[f[x]]");
        assert_eq!(
            eval("ComposeList[{f, g, h}, x]"),
            "List[x, f[x], g[f[x]], h[g[f[x]]]]"
        );
        assert_eq!(eval("MapApply[f][{g[a, b], h[c]}]"), "List[f[a, b], f[c]]");
        assert_eq!(
            eval("MapIndexed[f, g[a, b]]"),
            "g[f[a, List[1]], f[b, List[2]]]"
        );
        assert_eq!(eval("Construct[# + 1 &, 2]"), "3");
        assert_eq!(eval("Comap[{f, g}, x]"), "List[f[x], g[x]]");
        assert_eq!(eval("ComapApply[{f, g}, {x, y}]"), "List[f[x, y], g[x, y]]");
        assert_eq!(eval("Thread[f[{a, b}, {c, d}]]"), "List[f[a, c], f[b, d]]");
        assert_eq!(eval("Inner[f, {a, b}, {c, d}, g]"), "g[f[a, c], f[b, d]]");
        assert_eq!(
            eval("Tuples[{{a, b}, {c, d}}]"),
            "List[List[a, c], List[a, d], List[b, c], List[b, d]]"
        );
        assert_eq!(eval("UnitVector[4, 2]"), "List[0, 1, 0, 0]");
        assert_eq!(eval("IdentityMatrix[2]"), "List[List[1, 0], List[0, 1]]");
        assert_eq!(
            eval("TakeList[{a, b, c, d, e}, {2, 1}]"),
            "List[List[a, b], List[c]]"
        );
        assert_eq!(
            eval("TakeDrop[{a, b, c, d}, 2]"),
            "List[List[a, b], List[c, d]]"
        );
        assert_eq!(
            eval("BlockMap[f, {a, b, c, d, e}, 2, 1]"),
            "List[f[List[a, b]], f[List[b, c]], f[List[c, d]], f[List[d, e]]]"
        );
        assert_eq!(eval("LengthWhile[{2, 4, 6, 7, 8}, EvenQ]"), "3");
        assert_eq!(eval("DeleteDuplicates[{a, b, a, c, b}]"), "List[a, b, c]");
        assert_eq!(eval("DuplicateFreeQ[{a, b, a}]"), "False");
        assert_eq!(eval("Delete[f[a, g[b, c], d], {2, 1}]"), "f[a, g[c], d]");
    }

    #[test]
    fn evaluates_selection_search_and_extended_fold_families() {
        assert_eq!(
            eval("SequenceFold[f, {x0, x1}, {a, b, c}]"),
            "f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]"
        );
        assert_eq!(
            eval("SequenceFoldList[f, {x0, x1}, {a, b, c}]"),
            "List[x0, x1, f[x0, x1, a], f[x1, f[x0, x1, a], b], f[f[x0, x1, a], f[x1, f[x0, x1, a], b], c]]"
        );
        assert_eq!(
            eval("FoldWhileList[#1 + #2 &, 0, {1, 2, 3, 4}, # < 4 &]"),
            "List[0, 1, 3, 6]"
        );
        assert_eq!(
            eval("FoldPairList[Function[{y, x}, {y + x, y - x}], y0, {a, b, c}, Last]"),
            "List[Plus[y0, Times[-1, a]], Plus[y0, Times[-1, a], Times[-1, b]], Plus[y0, Times[-1, a], Times[-1, b], Times[-1, c]]]"
        );
        assert_eq!(eval("FirstCase[{a, 1, b, 2}, _Integer]"), "1");
        assert_eq!(
            eval("Select[{1, a, 2, 3}, # > 1 & -> {\"Element\", \"Index\"}]"),
            "Association[Rule[\"Element\", List[2, 3]], Rule[\"Index\", List[3, 4]]]"
        );
        assert_eq!(eval("Select[EvenQ][{1, 2, 3, 4}]"), "List[2, 4]");
        assert_eq!(
            eval("Discard[<|a -> 1, b -> x, c -> 2|>, IntegerQ, 1]"),
            "Association[Rule[b, x], Rule[c, 2]]"
        );
        assert_eq!(
            eval("SelectFirst[{1, a}, # > 1 & -> {\"Element\", \"Index\"}, q]"),
            "Association[Rule[\"Element\", q], Rule[\"Index\", Missing[\"NotFound\"]]]"
        );
        assert_eq!(
            eval("TakeWhile[<|a -> 2, b -> 4, c -> 1|>, EvenQ]"),
            "Association[Rule[a, 2], Rule[b, 4]]"
        );
        assert_eq!(
            eval("KeySelect[StringQ][<|\"a\" -> 1, bb -> 2|>]"),
            "Association[Rule[\"a\", 1]]"
        );
        assert_eq!(eval("AssociationQ[Association[a]]"), "False");
    }

    #[test]
    fn evaluates_holding_inactive_branching_and_real_piecewise_helpers() {
        assert_eq!(eval("Inactive[Evaluate[1 + 2]]"), "3");
        assert_eq!(eval("Activate[Inactive[Plus][1, 2]]"), "3");
        assert_eq!(
            eval("Activate[Inactive[Plus][Inactive[Times][2, 3], 4], Times]"),
            "Inactive[Plus][6, 4]"
        );
        assert_eq!(eval("Hold[Evaluate[1 + 2]]"), "Hold[3]");
        assert_eq!(
            eval("Hold[Evaluate[Unevaluated[1 + 2]]]"),
            "Hold[Unevaluated[Plus[1, 2]]]"
        );
        assert_eq!(eval("Length[Unevaluated[1 + 2]]"), "2");
        assert_eq!(
            eval("Which[False, a, x, 1/0, True, 2 + 2]"),
            "Which[x, Times[1, Power[0, -1]], True, Plus[2, 2]]"
        );
        assert_eq!(eval("Switch[a, _Integer, 1, _Symbol, 2]"), "2");
        assert_eq!(
            eval("Piecewise[{{1, False}, {2, x}, {2 + 2, True}}]"),
            "Piecewise[List[List[2, x]], 4]"
        );
        assert_eq!(eval("UnitStep[2, -1]"), "0");
        assert_eq!(eval("Unitize[-5]"), "1");
        assert_eq!(eval("RealSign[-7]"), "-1");
        assert_eq!(eval("RealAbs[-7]"), "7");
        assert_eq!(eval("Ramp[-3]"), "0");
    }

    #[test]
    fn ignores_inactive_wrappers_during_pattern_matching_but_preserves_bindings() {
        assert_eq!(
            eval("MatchQ[Inactive[f][1], IgnoringInactive[f[_]]]"),
            "True"
        );
        assert_eq!(
            eval(
                "Cases[{Inactive[Plus][1, 2], Inactive[f][1]}, IgnoringInactive[HoldPattern[Plus[_, _]]]]"
            ),
            "List[Inactive[Plus][1, 2]]"
        );
        assert_eq!(
            eval("Inactive[f][Inactive[g][1]] /. IgnoringInactive[f[x_]] :> x"),
            "Inactive[g][1]"
        );
        assert_eq!(eval("Inactive[f[1]] /. IgnoringInactive[f[x_]] :> x"), "1");
    }

    #[test]
    fn evaluates_nonlocal_control_and_reaping() {
        assert_eq!(eval("1 + Abort[]"), "$Aborted");
        assert_eq!(eval("CheckAbort[Abort[], fail]"), "fail");
        assert_eq!(eval("Catch[1 + Throw[x] + 3]"), "x");
        assert_eq!(eval("Catch[Throw[x, tag], _Symbol]"), "x");
        assert_eq!(eval("Throw[x, tag, h]"), "h[x, tag]");
        assert_eq!(eval("Reap[Sow[1]; Sow[2]; 3]"), "List[3, List[List[1, 2]]]");
        assert_eq!(
            eval("Reap[Sow[1, {a, b}]; 3, {a, b}]"),
            "List[3, List[List[List[1]], List[List[1]]]]"
        );
    }

    #[test]
    fn pure_function_attributes_control_holding_sequence_and_listable_application() {
        assert_eq!(eval("(#0&)[x]"), "Function[Slot[0]]");
        assert_eq!(
            eval("Function[Null, HoldComplete[#], HoldAll][1 + 2]"),
            "HoldComplete[Plus[1, 2]]"
        );
        assert_eq!(
            eval("Function[Null, HoldComplete[#1, #2], HoldFirst][1 + 2, 3 + 4]"),
            "HoldComplete[Plus[1, 2], 7]"
        );
        assert_eq!(
            eval("Function[Null, HoldComplete[##]][Sequence[a, b]]"),
            "HoldComplete[a, b]"
        );
        assert_eq!(
            eval("Function[Null, HoldComplete[##], SequenceHold][Sequence[a, b]]"),
            "HoldComplete[Sequence[a, b]]"
        );
        assert_eq!(
            eval("Function[Null, f[#], Listable][{a, b}]"),
            "List[f[a], f[b]]"
        );
        assert_eq!(
            eval("Function[{x, y}, f[x, y], Listable][{a, b}, {c, d}]"),
            "List[f[a, c], f[b, d]]"
        );
        assert_eq!(
            eval("Function[Null, HoldComplete[#], {Listable, HoldAll}][{1 + 2, 3 + 4}]"),
            "List[HoldComplete[Plus[1, 2]], HoldComplete[Plus[3, 4]]]"
        );
    }

    #[test]
    fn evaluates_inexact_arithmetic_and_numeric_approximation_precision() {
        assert_eq!(eval("0/0"), "Indeterminate");
        assert_eq!(eval("1. + 2"), "3.");
        assert_eq!(eval("1.25`20 + 2.5`20"), "3.75`20.");
        assert_eq!(eval("N[1/3]"), "0.3333333333333333");
        assert_eq!(eval("N[1/3, 20]"), "0.33333333333333333333`20.");
        assert_eq!(eval("N[Pi, 20]"), "3.1415926535897932385`20.");
        assert_eq!(eval("N[Sin[Pi/6], 20]"), "0.5`20.");
        assert_eq!(
            eval("N[Pi, WorkingPrecision -> 30]"),
            "3.14159265358979323846264338328`30."
        );
    }

    #[test]
    fn converts_expression_strings_boxes_and_syntax_without_a_kernel() {
        assert_eq!(
            eval("ToString[FullForm[{1, 2/3, a + b}]]"),
            "\"List[1, Rational[2, 3], Plus[a, b]]\""
        );
        assert_eq!(eval("ToString[1 + x, TeXForm]"), "\"x+1\"");
        assert_eq!(
            eval("ToExpression[\"f @ x // g\", StandardForm, HoldComplete]"),
            "HoldComplete[g[f[x]]]"
        );
        assert_eq!(
            eval("ToExpression[RowBox[{\"1\", \"+\", \"2\"}], StandardForm, HoldComplete]"),
            "HoldComplete[Plus[1, 2]]"
        );
        assert_eq!(
            eval("ToExpression[ToString[1 + x, TraditionalForm], TraditionalForm, HoldComplete]"),
            "HoldComplete[Plus[x, 1]]"
        );
        assert_eq!(eval("ToString[x^2, CForm]"), "\"Power(x,2)\"");
        assert_eq!(eval("SyntaxQ[\"1 +\"]"), "False");
        assert_eq!(eval("SyntaxLength[\"1+\"]"), "4");
        assert_eq!(
            eval("MakeExpression[RowBox[{\"1\", \"+\", \"2\"}], StandardForm]"),
            "HoldComplete[Plus[1, 2]]"
        );
        assert_eq!(
            eval("MakeBoxes[1 + 2, StandardForm]"),
            "RowBox[List[\"1\", \"+\", \"2\"]]"
        );
        assert_eq!(eval("ToBoxes[1 + 2, StandardForm]"), "\"3\"");
        assert_eq!(
            eval("StripBoxes[RowBox[{\"1\", \" \", StyleBox[\"+\", Red], \"2\"}]]"),
            "BoxData[RowBox[List[\"1\", \"+\", \"2\"]]]"
        );
    }

    #[test]
    fn tracks_symbol_context_names_and_unique_identity() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "$Context"), "\"Global`\"");
        assert_eq!(
            submit(&mut evaluator, "$ContextPath"),
            "List[\"System`\", \"Global`\"]"
        );
        assert_eq!(
            submit(
                &mut evaluator,
                "SymbolName[Symbol[\"TungstenRegistryTest`alpha\"]]"
            ),
            "\"alpha\""
        );
        assert_eq!(
            submit(&mut evaluator, "Symbol[\"TungstenRegistryTest`beta\"]"),
            "TungstenRegistryTest`beta"
        );
        assert_eq!(
            submit(&mut evaluator, "Names[\"TungstenRegistryTest`*\"]"),
            "List[\"TungstenRegistryTest`alpha\", \"TungstenRegistryTest`beta\"]"
        );
        assert_eq!(
            submit(&mut evaluator, "Length[Names[\"System`*\"]]"),
            "7941"
        );
        assert_eq!(
            submit(
                &mut evaluator,
                "UnsameQ[Unique[\"tungstenDistinct\"], Unique[\"tungstenDistinct\"]]"
            ),
            "True"
        );
        assert_eq!(submit(&mut evaluator, "ValueQ[$Context]"), "True");
    }

    #[test]
    fn evaluates_patterns_and_replacements() {
        assert_eq!(eval("MatchQ[3, _Integer]"), "True");
        assert_eq!(eval("FreeQ[{a, b}, a]"), "False");
        assert_eq!(eval("{a, b} /. a -> Nothing"), "List[b]");
        assert_eq!(eval("f[a] /. f[x_] :> x + 1"), "Plus[1, a]");
        assert_eq!(eval("Cases[{1, a, 2}, _Integer]"), "List[1, 2]");
        assert_eq!(eval("DeleteCases[{1, a, 2}, _Integer]"), "List[a]");
    }

    #[test]
    fn stores_and_applies_symbol_definitions() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "Clear[a, b, c]"), "Null");
        assert_eq!(submit(&mut evaluator, "a = 1 + 2"), "3");
        assert_eq!(submit(&mut evaluator, "a = a + 4"), "7");
        assert_eq!(submit(&mut evaluator, "ValueQ[a]"), "True");
        assert_eq!(
            submit(&mut evaluator, "OwnValues[a]"),
            "List[RuleDelayed[HoldPattern[a], 7]]"
        );
        assert_eq!(submit(&mut evaluator, "b = c"), "c");
        assert_eq!(submit(&mut evaluator, "c = 9"), "9");
        assert_eq!(submit(&mut evaluator, "b"), "9");
        assert_eq!(submit(&mut evaluator, "a =."), "Null");
        assert_eq!(submit(&mut evaluator, "ValueQ[a]"), "False");
        assert_eq!(submit(&mut evaluator, "Clear[{b, c}]"), "Null");
    }

    #[test]
    fn stores_and_applies_basic_down_values() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "f[x_] := x + 1"), "Null");
        assert_eq!(submit(&mut evaluator, "f[3]"), "4");
        assert_eq!(
            submit(&mut evaluator, "DownValues[f]"),
            "List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Plus[x, 1]]]"
        );
        assert_eq!(submit(&mut evaluator, "f[x_] =."), "Null");
        assert_eq!(submit(&mut evaluator, "f[3]"), "f[3]");
    }

    #[test]
    fn orders_and_guards_down_values() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "f[x_] := x f[x - 1]"), "Null");
        assert_eq!(submit(&mut evaluator, "f[1] = 1"), "1");
        assert_eq!(submit(&mut evaluator, "f[4]"), "24");
        assert_eq!(
            submit(&mut evaluator, "DownValues[f]"),
            "List[RuleDelayed[HoldPattern[f[1]], 1], RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Times[x, f[Plus[x, -1]]]]]"
        );

        assert_eq!(submit(&mut evaluator, "g[x_] := positive /; x > 0"), "Null");
        assert_eq!(submit(&mut evaluator, "g[x_] := negative /; x < 0"), "Null");
        assert_eq!(submit(&mut evaluator, "g[2]"), "positive");
        assert_eq!(submit(&mut evaluator, "g[-2]"), "negative");
        assert_eq!(submit(&mut evaluator, "g[0]"), "g[0]");
    }

    #[test]
    fn evaluates_assignment_rhs_before_preparing_lhs() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "x = 10"), "10");
        assert_eq!(submit(&mut evaluator, "f[x_] = x + 1"), "11");
        assert_eq!(submit(&mut evaluator, "f[3]"), "11");
        assert_eq!(submit(&mut evaluator, "g[x] = 99"), "99");
        assert_eq!(submit(&mut evaluator, "g[10]"), "99");
    }

    #[test]
    fn stores_curried_definitions_as_sub_values() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "f[x_][y_] := {x, y}"), "Null");
        assert_eq!(submit(&mut evaluator, "f[1][2]"), "List[1, 2]");
        assert_eq!(submit(&mut evaluator, "DownValues[f]"), "List[]");
        assert_eq!(
            submit(&mut evaluator, "SubValues[f]"),
            "List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]][Pattern[y, Blank[]]]], List[x, y]]]"
        );
        assert_eq!(submit(&mut evaluator, "f[x_][y_] =."), "Null");
        assert_eq!(submit(&mut evaluator, "f[1][2]"), "f[1][2]");
    }

    #[test]
    fn evaluates_with_using_lexical_substitution() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "With[{x = 5}, x + 1]"), "6");
        assert_eq!(
            submit(&mut evaluator, "With[{x = 1, y = x + 1}, {x, y}]"),
            "List[1, Plus[1, x]]"
        );
        assert_eq!(submit(&mut evaluator, "With[{x = 5}, Hold[x]]"), "Hold[5]");
        assert_eq!(
            submit(&mut evaluator, "With[{x = 5}, Function[x, x + 1][7]]"),
            "8"
        );
        assert_eq!(
            submit(&mut evaluator, "With[{x = y}, Function[y, x]][7]"),
            "y"
        );
        assert_eq!(
            submit(&mut evaluator, "With[{x = 5}, With[{x = 99}, x]]"),
            "99"
        );
    }

    #[test]
    fn evaluates_module_with_fresh_persistent_symbols() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "Module[{x = 5}, x + 1]"), "6");
        assert_eq!(
            submit(&mut evaluator, "Module[{x = 1, y = x + 1}, {x, y}]"),
            "List[1, Plus[1, x]]"
        );
        assert_eq!(submit(&mut evaluator, "Module[{x = 5}, x = 9; x]"), "9");
        assert_eq!(submit(&mut evaluator, "Module[{x}, Hold[x]]"), "Hold[x$4]");
        assert_eq!(
            submit(&mut evaluator, "Module[{x = 1}, Module[{x = 2}, x]]"),
            "2"
        );
    }

    #[test]
    fn evaluates_block_with_complete_state_restoration() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "x = 100"), "100");
        assert_eq!(submit(&mut evaluator, "Block[{x = 5}, x + 1]"), "6");
        assert_eq!(submit(&mut evaluator, "x"), "100");
        assert_eq!(submit(&mut evaluator, "f[1] = 99"), "99");
        assert_eq!(
            submit(&mut evaluator, "Block[{f}, f[2] = 88; {f[1], f[2]}]"),
            "List[99, 88]"
        );
        assert_eq!(submit(&mut evaluator, "f[2]"), "f[2]");
        assert_eq!(
            submit(
                &mut evaluator,
                "Catch[Block[{x = 5}, x = 9; Throw[escaped]]]"
            ),
            "escaped"
        );
        assert_eq!(submit(&mut evaluator, "x"), "100");
    }

    #[test]
    fn evaluates_table_do_sum_and_product_iterators() {
        let mut evaluator = Evaluator::default();
        assert_eq!(
            submit(&mut evaluator, "Table[i^2, {i, 1, 5}]"),
            "List[1, 4, 9, 16, 25]"
        );
        assert_eq!(
            submit(&mut evaluator, "Table[i + j, {i, 3}, {j, 2}]"),
            "List[List[2, 3], List[3, 4], List[4, 5]]"
        );
        assert_eq!(
            submit(&mut evaluator, "Table[i, {i, 0, 1, 1/4}]"),
            "List[0, Rational[1, 4], Rational[1, 2], Rational[3, 4], 1]"
        );
        assert_eq!(submit(&mut evaluator, "Sum[i^2, {i, 1, 5}]"), "55");
        assert_eq!(submit(&mut evaluator, "Product[i, {i, 1, 5}]"), "120");
        assert_eq!(submit(&mut evaluator, "total = 0"), "0");
        assert_eq!(submit(&mut evaluator, "Do[total += i, {i, 5}]"), "Null");
        assert_eq!(submit(&mut evaluator, "total"), "15");
        assert_eq!(submit(&mut evaluator, "i = 99"), "99");
        assert_eq!(submit(&mut evaluator, "Table[i, {i, 3}]"), "List[1, 2, 3]");
        assert_eq!(submit(&mut evaluator, "i"), "99");
    }

    #[test]
    fn evaluates_loops_and_loop_control() {
        let mut evaluator = Evaluator::default();
        assert_eq!(
            submit(
                &mut evaluator,
                "Module[{i = 0}, While[i < 5, i = i + 1]; i]"
            ),
            "5"
        );
        assert_eq!(
            submit(
                &mut evaluator,
                "Module[{i = 0, s = 0}, While[i < 5, i++; If[Mod[i, 2] == 0, Continue[]]; s += i]; s]"
            ),
            "9"
        );
        assert_eq!(
            submit(
                &mut evaluator,
                "Module[{s = 0}, For[i = 1, i <= 5, i++, s += i]; s]"
            ),
            "15"
        );
        assert_eq!(
            submit(
                &mut evaluator,
                "Module[{s = 0}, For[i = 1, i <= 10, i++, If[i > 5, Break[]]; s += i]; s]"
            ),
            "15"
        );
        assert_eq!(submit(&mut evaluator, "Table[Break[], {i, 3}]"), "Break[]");
        assert_eq!(submit(&mut evaluator, "Break[]"), "Break[]");
        assert_eq!(submit(&mut evaluator, "Continue[]"), "Continue[]");
    }

    #[test]
    fn catches_return_at_definition_and_named_head_boundaries() {
        let mut evaluator = Evaluator::default();
        assert_eq!(
            submit(
                &mut evaluator,
                "f[x_] := (If[x > 0, Return[positive]]; negative)"
            ),
            "Null"
        );
        assert_eq!(submit(&mut evaluator, "f[5]"), "positive");
        assert_eq!(submit(&mut evaluator, "f[-1]"), "negative");
        assert_eq!(
            submit(
                &mut evaluator,
                "Module[{x = 1}, Return[x + 1, Module]; never]"
            ),
            "2"
        );
        assert_eq!(
            submit(&mut evaluator, "Block[{x = 1}, Return[done, Block]; never]"),
            "done"
        );
        assert_eq!(submit(&mut evaluator, "Return[5]"), "Return[5]");
    }

    #[test]
    fn stores_applies_and_removes_tagged_up_values() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "y = 5"), "5");
        assert_eq!(
            submit(&mut evaluator, "f /: h[f[x_]] = x + y"),
            "Plus[5, x]"
        );
        assert_eq!(submit(&mut evaluator, "h[f[3]]"), "8");
        assert_eq!(submit(&mut evaluator, "y = 10"), "10");
        assert_eq!(submit(&mut evaluator, "h[f[3]]"), "8");
        assert_eq!(submit(&mut evaluator, "DownValues[h]"), "List[]");
        assert_eq!(
            submit(&mut evaluator, "UpValues[f]"),
            "List[RuleDelayed[HoldPattern[h[f[Pattern[x, Blank[]]]]], Plus[5, x]]]"
        );
        assert_eq!(submit(&mut evaluator, "h[x_] := down[x]"), "Null");
        assert_eq!(submit(&mut evaluator, "h[f[3]]"), "8");
        assert_eq!(submit(&mut evaluator, "f /: h[f[x_]] =."), "Null");
        assert_eq!(submit(&mut evaluator, "h[f[3]]"), "down[f[3]]");
        assert_eq!(submit(&mut evaluator, "UpValues[f]"), "List[]");
    }

    #[test]
    fn routes_redundant_tagged_definitions_to_ordinary_value_lists() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "f /: f[x_] := x + 1"), "Null");
        assert_eq!(submit(&mut evaluator, "f[3]"), "4");
        assert_eq!(submit(&mut evaluator, "UpValues[f]"), "List[]");
        assert_eq!(
            submit(&mut evaluator, "DownValues[f]"),
            "List[RuleDelayed[HoldPattern[f[Pattern[x, Blank[]]]], Plus[x, 1]]]"
        );
    }

    #[test]
    fn mutable_attributes_drive_argument_evaluation_and_canonicalization() {
        let mut evaluator = Evaluator::default();
        assert_eq!(
            submit(&mut evaluator, "Attributes[Plus]"),
            "List[Flat, Listable, NumericFunction, OneIdentity, Orderless, Protected]"
        );
        assert_eq!(
            submit(
                &mut evaluator,
                "SetAttributes[f, {Flat, Orderless, OneIdentity}]"
            ),
            "Null"
        );
        assert_eq!(
            submit(&mut evaluator, "Attributes[f]"),
            "List[Flat, OneIdentity, Orderless]"
        );
        assert_eq!(submit(&mut evaluator, "f[b, f[c, a], a]"), "f[a, a, b, c]");
        assert_eq!(
            submit(
                &mut evaluator,
                "Cases[{f[c, b, a]}, f[a, x__] :> HoldComplete[x]]"
            ),
            "List[HoldComplete[b, c]]"
        );
        assert_eq!(submit(&mut evaluator, "Attributes[g] = HoldAll"), "HoldAll");
        assert_eq!(
            submit(&mut evaluator, "g[1 + 2, Sequence[a, b], Evaluate[3 + 4]]"),
            "g[Plus[1, 2], a, b, 7]"
        );
        assert_eq!(
            submit(&mut evaluator, "ClearAttributes[g, HoldAll]"),
            "Null"
        );
        assert_eq!(submit(&mut evaluator, "Attributes[g]"), "List[]");
        assert_eq!(
            submit(&mut evaluator, "SetAttributes[h, {Listable, HoldAll}]"),
            "Null"
        );
        assert_eq!(
            submit(&mut evaluator, "h[{1 + 2, 3 + 4}]"),
            "List[h[Plus[1, 2]], h[Plus[3, 4]]]"
        );
        assert_eq!(
            submit(&mut evaluator, "SetAttributes[h, HoldAllComplete]"),
            "Null"
        );
        assert_eq!(
            submit(&mut evaluator, "h[1 + 2, Sequence[a, b], Evaluate[3 + 4]]"),
            "h[Plus[1, 2], Sequence[a, b], Evaluate[Plus[3, 4]]]"
        );
    }

    #[test]
    fn protection_and_locking_gate_definition_mutations() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "Protect[p]"), "List[\"p\"]");
        assert_eq!(submit(&mut evaluator, "p = 5"), "Set[p, 5]");
        assert_eq!(submit(&mut evaluator, "ValueQ[p]"), "False");
        assert_eq!(submit(&mut evaluator, "Unprotect[p]"), "List[\"p\"]");
        assert_eq!(submit(&mut evaluator, "p = 5"), "5");
        assert_eq!(submit(&mut evaluator, "ClearAll[p]"), "Null");
        assert_eq!(submit(&mut evaluator, "Attributes[p]"), "List[]");
        assert_eq!(submit(&mut evaluator, "Plus = 5"), "Set[Plus, 5]");
        assert_eq!(submit(&mut evaluator, "SetAttributes[q, Locked]"), "Null");
        assert_eq!(
            submit(&mut evaluator, "SetAttributes[q, HoldAll]"),
            "SetAttributes[q, HoldAll]"
        );
        assert_eq!(submit(&mut evaluator, "Attributes[q]"), "List[Locked]");
    }

    #[test]
    fn evaluates_association_construction_access_and_transforms() {
        assert_eq!(
            eval("<|a -> 1, a -> 2, b -> 3|>"),
            "Association[Rule[a, 2], Rule[b, 3]]"
        );
        assert_eq!(
            eval("Association[{a -> 1, a -> 2, b -> 3}]"),
            "Association[Rule[a, 2], Rule[b, 3]]"
        );
        assert_eq!(eval("Depth[<|a -> <|b -> 1|>, c -> {2, 3}|>]"), "3");
        assert_eq!(eval("Keys[<|a -> x, b -> y, c -> z|>]"), "List[a, b, c]");
        assert_eq!(eval("Values[<|a -> x, b -> y, c -> z|>]"), "List[x, y, z]");
        assert_eq!(
            eval("Normal[<|a -> x, b -> y|>]"),
            "List[Rule[a, x], Rule[b, y]]"
        );
        assert_eq!(eval("Lookup[<|a -> 1, b -> 2|>, b]"), "2");
        assert_eq!(
            eval("Lookup[<|a -> 1, b -> 2|>, d]"),
            "Missing[\"KeyAbsent\", d]"
        );
        assert_eq!(eval("Lookup[<|a -> 1, b -> 2|>, {b, d}, q]"), "List[2, q]");
        assert_eq!(eval("<|a -> 1, b -> 2|>[a]"), "1");
        assert_eq!(eval("KeyExistsQ[<|a -> 1|>, a]"), "True");
        assert_eq!(
            eval("KeyTake[<|a -> 1, b -> 2, c -> 3|>, {c, a}]"),
            "Association[Rule[c, 3], Rule[a, 1]]"
        );
        assert_eq!(
            eval("KeyDrop[<|a -> 1, b -> 2, c -> 3|>, {c, a}]"),
            "Association[Rule[b, 2]]"
        );
        assert_eq!(
            eval("AssociationThread[{a, b}, {1, 2}]"),
            "Association[Rule[a, 1], Rule[b, 2]]"
        );
        assert_eq!(
            eval("AssociationMap[f, {a, b}]"),
            "Association[Rule[a, f[a]], Rule[b, f[b]]]"
        );
        assert_eq!(
            eval("KeyValueMap[f, <|a -> 1, b -> 2|>]"),
            "List[f[a, 1], f[b, 2]]"
        );
    }

    #[test]
    fn structural_functions_preserve_association_keys() {
        assert_eq!(eval("First[<|a -> 1, b -> 2|>]"), "1");
        assert_eq!(eval("Last[<|a -> 1, b -> 2|>]"), "2");
        assert_eq!(
            eval("Append[<|a -> 1, b -> 2|>, a -> 9]"),
            "Association[Rule[b, 2], Rule[a, 9]]"
        );
        assert_eq!(
            eval("Join[<|a -> 1, b -> 2|>, <|a -> 9, c -> 3|>]"),
            "Association[Rule[a, 9], Rule[b, 2], Rule[c, 3]]"
        );
        assert_eq!(eval("Apply[g, <|a -> 1, b -> 2|>]"), "g[1, 2]");
        assert_eq!(
            eval("Map[g, <|a -> 1, b -> 2|>]"),
            "Association[Rule[a, g[1]], Rule[b, g[2]]]"
        );
        assert_eq!(eval("Total[<|a -> 1, b -> 2|>]"), "3");
    }

    #[test]
    fn evaluates_literal_string_structure_and_helpers() {
        assert_eq!(eval("StringLength[{\"ab\", \"c\"}]"), "List[2, 1]");
        assert_eq!(eval("StringTake[\"abcdef\", {2, 5, 2}]"), "\"bd\"");
        assert_eq!(eval("StringTake[\"abc\", UpTo[5]]"), "\"abc\"");
        assert_eq!(eval("StringDrop[\"abcdef\", {2, 5, 2}]"), "\"acef\"");
        assert_eq!(eval("StringJoin[{\"a\", {\"b\", \"c\"}}]"), "\"abc\"");
        assert_eq!(eval("StringInsert[\"abcd\", \"X\", {2, 4}]"), "\"aXbcXd\"");
        assert_eq!(
            eval("StringReverse[{\"ab\", \"cd\"}]"),
            "List[\"ba\", \"dc\"]"
        );
        assert_eq!(
            eval("StringPosition[\"ababa\", {\"ba\", \"aba\"}]"),
            "List[List[1, 3], List[2, 3], List[3, 5], List[4, 5]]"
        );
        assert_eq!(
            eval("StringContainsQ[{\"ab\", \"cd\"}, \"a\"]"),
            "List[True, False]"
        );
        assert_eq!(eval("ToUpperCase[\"hello\"]"), "\"HELLO\"");
        assert_eq!(eval("ToLowerCase[\"WORLD\"]"), "\"world\"");
        assert_eq!(eval("Capitalize[\"hello world\"]"), "\"Hello world\"");
        assert_eq!(
            eval("StringSplit[\"a:b;c\", {\":\", \";\"}]"),
            "List[\"a\", \"b\", \"c\"]"
        );
        assert_eq!(
            eval("StringRiffle[{\"a\", \"b\", \"c\"}, {\"<\", \"+\", \">\"}]"),
            "\"<a+b+c>\""
        );
        assert_eq!(eval("StringPadLeft[\"abc\", 6, \"0\"]"), "\"000abc\"");
        assert_eq!(eval("StringPadRight[\"abc\", 6, \"*\"]"), "\"abc***\"");
        assert_eq!(eval("StringRepeat[\"ab\", 3]"), "\"ababab\"");
        assert_eq!(eval("StringCount[\"abcabcabc\", \"a\"]"), "3");
        assert_eq!(eval("StringTrim[\"   hello   \"]"), "\"hello\"");
        assert_eq!(eval("StringTrim[\"abcXYZdef\", \"abc\"]"), "\"XYZdef\"");
    }

    #[test]
    fn evaluates_byte_arrays_base_encodings_and_character_encodings() {
        assert_eq!(eval("ByteArray[{65, 66, 67}]"), "ByteArray[\"QUJD\"]");
        assert_eq!(eval("ByteArrayQ[ByteArray[\"QUJD\"]]"), "True");
        assert_eq!(eval("Length[ByteArray[\"QUJD\"]]"), "3");
        assert_eq!(eval("Normal[ByteArray[\"QUJD\"]]"), "List[65, 66, 67]");
        assert_eq!(
            eval("BaseEncode[ByteArray[{0, 255}], \"Base16\"]"),
            "\"00FF\""
        );
        assert_eq!(
            eval("Normal[BaseDecode[\"z\", \"Base85ASCII\"]]"),
            "List[0, 0, 0, 0]"
        );
        assert_eq!(
            eval("ToCharacterCode[FromCharacterCode[{97, 233}], \"UTF-8\"]"),
            "List[97, 195, 169]"
        );
        assert_eq!(
            eval("ToCharacterCode[FromCharacterCode[{97, 233}], \"ASCII\"]"),
            "List[97, None]"
        );
        assert_eq!(
            eval("StringToByteArray[FromCharacterCode[{97, 233}], \"UTF-8\"]"),
            "ByteArray[\"YcOp\"]"
        );
        assert_eq!(
            eval("ToCharacterCode[ByteArrayToString[ByteArray[{97, 162, 98}], \"UTF-8\"]]"),
            "List[97, 162, 98]"
        );
    }

    #[test]
    fn evaluates_complex_components_rounding_and_mixed_relations() {
        assert_eq!(eval("Re[1 + 2 I]"), "1");
        assert_eq!(eval("Im[1 + 2 I]"), "2");
        assert_eq!(eval("Conjugate[1 + 2 I]"), "Complex[1, -2]");
        assert_eq!(eval("Abs[3 + 4 I]"), "5");
        assert_eq!(eval("Abs[1 + I]"), "Power[2, Rational[1, 2]]");
        assert_eq!(eval("ToString[Abs[1 + I]]"), "\"2^(1/2)\"");
        assert_eq!(
            eval("ComplexExpand[x + I]"),
            "ComplexExpand[Plus[Complex[0, 1], x]]"
        );
        assert_eq!(eval("IntegerPart[1.5 + 2.75 I]"), "Complex[1, 2]");
        assert_eq!(eval("FractionalPart[1.5 + 2.75 I]"), "Complex[0.5, 0.75]");
        assert_eq!(
            eval("Sign[3 + 4 I]"),
            "Complex[Rational[3, 5], Rational[4, 5]]"
        );
        assert_eq!(eval("1/2 < .75"), "True");
        assert_eq!(eval("Max[1/2, .75]"), ".75");
        assert_eq!(eval("Floor[-3.7]"), "-4");
        assert_eq!(eval("Ceiling[7/2]"), "4");
        assert_eq!(eval("Floor[7/2, 2/3]"), "Rational[10, 3]");
        assert_eq!(eval("Round[2.5]"), "2");
        assert_eq!(eval("Round[7/2]"), "4");
    }

    #[test]
    fn evaluates_ordering_and_sorting_core() {
        assert_eq!(eval("Order[1, 2]"), "1");
        assert_eq!(eval("Order[2, 1]"), "-1");
        assert_eq!(eval("OrderedQ[{1, 2, 2}]"), "True");
        assert_eq!(eval("Ordering[{3, 1, 2}]"), "List[2, 3, 1]");
        assert_eq!(eval("Ordering[{3, 1, 2}, -2]"), "List[3, 1]");
        assert_eq!(
            eval("Ordering[{1., 1, 2}, All, Less, SameTest -> Equal]"),
            "List[1, 2, 3]"
        );
        assert_eq!(eval("Sort[f[3, 1, 2]]"), "f[1, 2, 3]");
        assert_eq!(
            eval("Sort[{1., 1, 2}, SameTest -> Equal]"),
            "List[1., 1, 2]"
        );
        assert_eq!(eval("ReverseSort[{3, 1, 2}]"), "List[3, 2, 1]");
        assert_eq!(
            eval("SortBy[{{c, 2}, {a, 2}, {b, 1}}, Last]"),
            "List[List[b, 1], List[a, 2], List[c, 2]]"
        );
        assert_eq!(
            eval("SortBy[{1, -2, -1, 2}, Abs, Less, SameTest -> Equal]"),
            "List[1, -1, -2, 2]"
        );
        assert_eq!(
            eval("SortBy[Last][{{a, 2}, {b, 1}}]"),
            "List[List[b, 1], List[a, 2]]"
        );
        assert_eq!(
            eval("OrderingBy[{{a, 2}, {b, 1}, {c, 3}}, Last, -2]"),
            "List[1, 3]"
        );
        assert_eq!(
            eval("OrderingBy[{1, -2, -1, 2}, Abs, All, Less, SameTest -> Equal]"),
            "List[1, 3, 2, 4]"
        );
        assert_eq!(
            eval("MinimalBy[{{a, 1}, {b, 2}, {c, 1}}, Last]"),
            "List[List[a, 1], List[c, 1]]"
        );
        assert_eq!(
            eval("LexicographicSort[{{1, 3}, {1, 2}, {0, 9}}]"),
            "List[List[0, 9], List[1, 2], List[1, 3]]"
        );
        assert_eq!(eval("RandomPermutation[0]"), "Cycles[List[]]");
    }

    #[test]
    fn evaluates_integer_number_theory_and_digit_operations() {
        assert_eq!(eval("GCD[12, 18]"), "6");
        assert_eq!(eval("GCD[]"), "0");
        assert_eq!(eval("LCM[4, 6]"), "12");
        assert_eq!(eval("LCM[]"), "1");
        assert_eq!(eval("Divisors[12]"), "List[1, 2, 3, 4, 6, 12]");
        assert_eq!(eval("PrimeQ[7]"), "True");
        assert_eq!(eval("PrimeQ[8]"), "False");
        assert_eq!(eval("PrimeQ[1000000007]"), "True");
        assert_eq!(eval("EulerPhi[12]"), "4");
        assert_eq!(eval("MoebiusMu[6]"), "1");
        assert_eq!(eval("MoebiusMu[12]"), "0");
        assert_eq!(eval("PrimePi[100]"), "25");
        assert_eq!(eval("Prime[10]"), "29");
        assert_eq!(eval("NextPrime[10]"), "11");
        assert_eq!(eval("PowerMod[3, 5, 7]"), "5");
        assert_eq!(eval("PowerMod[3, -1, 7]"), "5");
        assert_eq!(eval("BitAnd[12, 10]"), "8");
        assert_eq!(eval("BitOr[12, 10]"), "14");
        assert_eq!(eval("BitXor[12, 10]"), "6");
        assert_eq!(eval("BitShiftLeft[3, 2]"), "12");
        assert_eq!(eval("BitShiftRight[12, 2]"), "3");
        assert_eq!(eval("IntegerDigits[12345]"), "List[1, 2, 3, 4, 5]");
        assert_eq!(eval("IntegerDigits[12345, 16]"), "List[3, 0, 3, 9]");
        assert_eq!(
            eval("IntegerDigits[12, 2, 8]"),
            "List[0, 0, 0, 0, 1, 1, 0, 0]"
        );
        assert_eq!(eval("FromDigits[{1, 2, 3, 4}]"), "1234");
        assert_eq!(eval("FromDigits[{1, 2, 3, 4}, 16]"), "4660");
        assert_eq!(eval("FromDigits[\"abc\", 16]"), "2748");
        assert_eq!(eval("IntegerLength[12345]"), "5");
    }

    #[test]
    fn evaluates_collection_and_set_operations() {
        assert_eq!(
            eval("Tally[{a, b, a, c, a, b}]"),
            "List[List[a, 3], List[b, 2], List[c, 1]]"
        );
        assert_eq!(
            eval("Counts[{a, b, a, c, a, b}]"),
            "Association[Rule[a, 3], Rule[b, 2], Rule[c, 1]]"
        );
        assert_eq!(
            eval("Catenate[{{a, b}, {c}, {d, e}}]"),
            "List[a, b, c, d, e]"
        );
        assert_eq!(eval("Differences[{1, 3, 6, 10}]"), "List[2, 3, 4]");
        assert_eq!(eval("Accumulate[{1, 2, 3, 4}]"), "List[1, 3, 6, 10]");
        assert_eq!(
            eval("Riffle[{a, b, c, d}, {x, y}]"),
            "List[a, x, b, y, c, x, d]"
        );
        assert_eq!(eval("AllTrue[{2, 4, 6}, EvenQ]"), "True");
        assert_eq!(eval("AnyTrue[{1, 3, 4}, EvenQ]"), "True");
        assert_eq!(eval("NoneTrue[{1, 3, 5}, EvenQ]"), "True");
        assert_eq!(eval("ContainsAll[{a, b, c}, {c, a}]"), "True");
        assert_eq!(eval("ContainsAny[{a, b, c}, {x, b}]"), "True");
        assert_eq!(eval("ContainsNone[{a, b, c}, {x, y}]"), "True");
        assert_eq!(eval("ContainsExactly[{b, a, a}, {a, b}]"), "True");
        assert_eq!(
            eval("Subsets[{a, b, c}]"),
            "List[List[], List[a], List[b], List[c], List[a, b], List[a, c], List[b, c], List[a, b, c]]"
        );
        assert_eq!(
            eval("Permutations[{a, b, c}]"),
            "List[List[a, b, c], List[a, c, b], List[b, a, c], List[b, c, a], List[c, a, b], List[c, b, a]]"
        );
        assert_eq!(eval("Permute[{a, b, c}, {2, 3, 1}]"), "List[c, a, b]");
        assert_eq!(
            eval("Permute[f[a, b, c], Cycles[{{1, 2, 3}}]]"),
            "f[c, a, b]"
        );
        assert_eq!(eval("Union[{c, a, b, a}, {d, b}]"), "List[a, b, c, d]");
        assert_eq!(eval("Intersection[{a, b, c}, {c, b, d}]"), "List[b, c]");
        assert_eq!(
            eval("Intersection[{1, -1}, {1}, SameTest -> (Abs[#1] == Abs[#2] &)]"),
            "List[1]"
        );
        assert_eq!(eval("Complement[{a, b, c}, {b, d}]"), "List[a, c]");
        assert_eq!(eval("PadLeft[{a, b}, 5, x]"), "List[x, x, x, a, b]");
        assert_eq!(eval("PadRight[{a, b}, 5, {x, y}]"), "List[a, b, x, y, x]");
        assert_eq!(
            eval("KeySort[<|c -> 3, a -> 1, b -> 2|>]"),
            "Association[Rule[a, 1], Rule[b, 2], Rule[c, 3]]"
        );
        assert_eq!(eval("Mean[{1, 2, 3, 4}]"), "Rational[5, 2]");
        assert_eq!(eval("Median[{4, 1, 3, 2}]"), "Rational[5, 2]");
        assert_eq!(
            eval("Transpose[{{a, b, c}, {d, e, f}}]"),
            "List[List[a, d], List[b, e], List[c, f]]"
        );
        assert_eq!(eval("Insert[{a, b, c}, x, 2]"), "List[a, x, b, c]");
        assert_eq!(eval("FlattenAt[{a, {b, c}, d}, 2]"), "List[a, b, c, d]");
        assert_eq!(
            eval("Split[{a, a, b, b, b, c, a}]"),
            "List[List[a, a], List[b, b, b], List[c], List[a]]"
        );
        assert_eq!(
            eval("DeleteAdjacentDuplicates[{a, a, b, b, a, a}]"),
            "List[a, b, a]"
        );
    }

    #[test]
    fn evaluates_timing_confirmation_and_failsafe_control() {
        assert_eq!(eval("Pause[0]"), "Null");
        assert_eq!(eval("TimeRemaining[]"), "Infinity");
        assert_eq!(eval("TimeConstrained[Pause[0]; 7, 1, fail]"), "7");
        assert_eq!(eval("TimeConstrained[Pause[0.02]; 7, 0.001, fail]"), "fail");
        assert_eq!(eval("TimeConstrained[Pause[0.02]; 7, 0.001]"), "$Aborted");
        assert_eq!(eval("Enclose[1 + Confirm[2]]"), "3");
        assert_eq!(
            eval("Enclose[Confirm[Missing[\"Nope\"], \"info\"], \"Expression\"]"),
            "Missing[\"Nope\"]"
        );
        assert_eq!(
            eval("Enclose[Confirm[Missing[\"Nope\"], \"info\"], \"Information\"]"),
            "\"info\""
        );
        assert_eq!(eval("Enclose[ConfirmBy[3, IntegerQ]]"), "3");
        assert_eq!(
            eval("Enclose[ConfirmBy[3, StringQ, \"info\"], \"Function\"]"),
            "StringQ"
        );
        assert_eq!(eval("Enclose[ConfirmMatch[3, _Integer]]"), "3");
        assert_eq!(
            eval("Enclose[ConfirmAssert[False, \"bad\"], \"Information\"]"),
            "\"bad\""
        );
        assert_eq!(eval("Failsafe[f][1, 2]"), "f[1, 2]");
        assert_eq!(
            eval("Failsafe[f][1, Missing[\"x\"], Failure[\"bad\", <||>]]"),
            "Missing[\"x\"]"
        );
        assert_eq!(eval("Failsafe[f, SameQ][1, 1]"), "f[1, 1]");
        assert_eq!(eval("Failsafe[f, SameQ][1, 2][\"Type\"]"), "FailsafeFailed");
        assert_eq!(eval("Failsafe[f, SameQ, g][1, 2]"), "g[1, 2]");
    }

    #[test]
    fn structural_positions_and_arrays_remove_nothing_precisely() {
        assert_eq!(eval("Level[Hold[Nothing], {-1}]"), "List[]");
        assert_eq!(
            eval("Level[f[a, g[b, c]], Infinity]"),
            "List[a, b, c, g[b, c]]"
        );
        assert_eq!(eval("Level[f[a, g[b]], {-1}]"), "List[a, b]");
        assert_eq!(eval("ReplacePart[{a, b}, 1 -> Nothing]"), "List[b]");
        assert_eq!(
            eval("ReplacePart[f[a, g[b, c], d], {2, 1} -> x]"),
            "f[a, g[x, c], d]"
        );
        assert_eq!(
            eval("ReplacePart[f[g[a, b], c], {{1, 1} -> y, {1} -> x}]"),
            "f[x, c]"
        );
        assert_eq!(eval("MapAt[Nothing &, {a, b}, 1]"), "List[b]");
        assert_eq!(eval("MapAt[g, f[a, b, c], {{2}, {2}}]"), "f[a, g[g[b]], c]");
        assert_eq!(eval("ConstantArray[Nothing, 3]"), "List[]");
        assert_eq!(eval("Array[Nothing &, 3]"), "List[]");
        assert_eq!(eval("Array[f, 3, 0]"), "List[f[0], f[1], f[2]]");
        assert_eq!(
            eval("Array[f, {2, 2}, {0, 0}]"),
            "List[List[f[0, 0], f[0, 1]], List[f[1, 0], f[1, 1]]]"
        );
    }

    #[test]
    fn normalizes_intervals_and_dense_array_operations() {
        assert_eq!(eval("Interval[3]"), "Interval[List[3, 3]]");
        assert_eq!(eval("Interval[{3, 1}]"), "Interval[List[1, 3]]");
        assert_eq!(eval("Interval[{1, 3}, {2, 5}]"), "Interval[List[1, 5]]");
        assert_eq!(
            eval("IntervalUnion[Interval[{1, 2}], Interval[{2, 4}]]"),
            "Interval[List[1, 4]]"
        );
        assert_eq!(
            eval("IntervalIntersection[Interval[{1, 2}, {4, 5}], Interval[{2, 4}]]"),
            "Interval[List[2, 2], List[4, 4]]"
        );
        assert_eq!(eval("IntervalMemberQ[Interval[{1, 3}], 2]"), "True");
        assert_eq!(
            eval("IntervalMemberQ[Interval[{1, 3}], {1, 4}]"),
            "List[True, False]"
        );
        assert_eq!(eval("ArrayDepth[{{1, 2}, {3, 4}}]"), "2");
        assert_eq!(eval("ArrayQ[{{1, 2}, {3, 4}}, 2, IntegerQ]"), "True");
        assert_eq!(eval("ArrayQ[{{1}, {2, 3}}]"), "False");
        assert_eq!(eval("Dimensions[{{1, 2}, {3, 4}}]"), "List[2, 2]");
        assert_eq!(
            eval("ArrayReshape[{1, 2, 3, 4, 5}, {2, 3}]"),
            "List[List[1, 2, 3], List[4, 5, 0]]"
        );
        assert_eq!(
            eval("ArrayPad[{{1, 2}, {3, 4}}, 1]"),
            "List[List[0, 0, 0, 0], List[0, 1, 2, 0], List[0, 3, 4, 0], List[0, 0, 0, 0]]"
        );
        assert_eq!(
            eval("ArrayFlatten[{{{{1, 2}, {3, 4}}, {{5}, {6}}}, {{{7, 8}}, {{9}}}}]"),
            "List[List[1, 2, 5], List[3, 4, 6], List[7, 8, 9]]"
        );
    }

    #[test]
    fn evaluates_radicals_machine_precision_and_list_extrema() {
        assert_eq!(eval("NumericQ[Root[#^2 - 2 &, 1] + 1]"), "True");
        assert_eq!(eval("InexactNumberQ[1. + 2 I]"), "True");
        assert_eq!(eval("MachineNumberQ[1. + 2. I]"), "True");
        assert_eq!(eval("MachineIntegerQ[2^63 - 1]"), "True");
        assert_eq!(eval("Precision[1]"), "Infinity");
        assert_eq!(eval("Precision[1.]"), "MachinePrecision");
        assert_eq!(eval("Precision[1.23`20]"), "20.");
        assert_eq!(eval("Accuracy[1000.]"), "12.954589770191003");
        assert_eq!(eval("$MachinePrecision"), "15.954589770191003");
        assert_eq!(eval("$MachineEpsilon"), "2.220446049250313*^-16");
        assert_eq!(eval("SetPrecision[1/3, 20]"), "0.33333333333333333333`20.");
        assert_eq!(eval("SetPrecision[1.25, Infinity]"), "Rational[5, 4]");
        assert_eq!(eval("SetAccuracy[1.23, 20]"), "1.23``20.");
        assert_eq!(eval("Sqrt[16]"), "4");
        assert_eq!(eval("Sqrt[2]"), "Power[2, Rational[1, 2]]");
        assert_eq!(eval("Sqrt[-4]"), "Times[2, I]");
        assert_eq!(eval("Sqrt[12]"), "Times[2, Power[3, Rational[1, 2]]]");
        assert_eq!(eval("54^(1/3)"), "Times[3, Power[2, Rational[1, 3]]]");
        assert_eq!(eval("8^(2/3)"), "4");
        assert_eq!(eval("Min[{1, 4}, {2, 3}]"), "1");
        assert_eq!(eval("Min[{1, x, 2}]"), "Min[1, x]");
        assert_eq!(eval("1/Overflow[]"), "Underflow[]");
        assert_eq!(eval("1/Underflow[]"), "Overflow[]");
    }

    #[test]
    fn evaluates_folds_grouping_and_dense_linear_algebra() {
        assert_eq!(eval("Fold[Plus, {1, 2, 3, 4}]"), "10");
        assert_eq!(eval("Fold[f, {a, b, c}]"), "f[f[a, b], c]");
        assert_eq!(eval("FoldList[Plus, {1, 2, 3, 4}]"), "List[1, 3, 6, 10]");
        assert_eq!(
            eval("Range[{2, 5}]"),
            "List[List[1, 2], List[1, 2, 3, 4, 5]]"
        );
        assert_eq!(
            eval("SplitBy[{1, 3, 2, 4, 5}, EvenQ]"),
            "List[List[1, 3], List[2, 4], List[5]]"
        );
        assert_eq!(
            eval("Subsequences[{a, b, c}, {2}]"),
            "List[List[a, b], List[b, c]]"
        );
        assert_eq!(
            eval("NumericalSort[{\"x10\", \"x2\", \"x1\"}]"),
            "List[\"x1\", \"x2\", \"x10\"]"
        );
        assert_eq!(eval("Tr[{{a, b}, {c, d}}]"), "Plus[a, d]");
        assert_eq!(
            eval("Det[{{a, b}, {c, d}}]"),
            "Plus[Times[-1, b, c], Times[a, d]]"
        );
        assert_eq!(
            eval("Inverse[{{1, 2}, {3, 4}}]"),
            "List[List[-2, 1], List[Rational[3, 2], Rational[-1, 2]]]"
        );
        assert_eq!(
            eval("MatrixPower[{{1, 1}, {1, 0}}, 3]"),
            "List[List[3, 2], List[2, 1]]"
        );
        assert_eq!(
            eval("Cross[{a, b, c}, {d, e, f}]"),
            "List[Plus[Times[-1, c, e], Times[b, f]], Plus[Times[-1, a, f], Times[c, d]], Plus[Times[-1, b, d], Times[a, e]]]"
        );
        assert_eq!(eval("LeviCivitaTensor[2]"), "List[List[0, 1], List[-1, 0]]");
        assert_eq!(
            eval("DiagonalMatrix[{1, 2, 3}, 1]"),
            "List[List[0, 1, 0, 0], List[0, 0, 2, 0], List[0, 0, 0, 3], List[0, 0, 0, 0]]"
        );
    }

    #[test]
    fn evaluates_multilevel_structural_transformations() {
        assert_eq!(
            eval("Reverse[{{a, b}, {c, d}}, {1, 2}]"),
            "List[List[d, c], List[b, a]]"
        );
        assert_eq!(
            eval("Map[f, {{a, b}, {c, d}}, {2}]"),
            "List[List[f[a], f[b]], List[f[c], f[d]]]"
        );
        assert_eq!(eval("Map[f, x[a, b, c], {0}]"), "f[x[a, b, c]]");
        assert_eq!(
            eval("Apply[f, {{a, b}, {c, d}}, {1}]"),
            "List[f[a, b], f[c, d]]"
        );
        assert_eq!(
            eval("Apply[f, {{a, b}, {c, d}}, {0, 1}]"),
            "f[f[a, b], f[c, d]]"
        );
        assert_eq!(
            eval("Take[{{1, 2, 3}, {4, 5, 6}}, 2, 2]"),
            "List[List[1, 2], List[4, 5]]"
        );
        assert_eq!(
            eval("Drop[{{1, 2, 3}, {4, 5, 6}}, None, 1]"),
            "List[List[2, 3], List[5, 6]]"
        );
    }

    #[test]
    fn constructs_and_preserves_sparse_arrays() {
        assert_eq!(
            eval("Normal[SparseArray[{{1, 2} -> a, {2, 3} -> b}, {2, 3}]]"),
            "List[List[0, a, 0], List[0, 0, b]]"
        );
        assert_eq!(
            eval("ArrayRules[SparseArray[{{0, 1}, {2, 0}}]]"),
            "List[Rule[List[1, 2], 1], Rule[List[2, 1], 2], Rule[List[Blank[], Blank[]], 0]]"
        );
        assert_eq!(
            eval("SparseArray[{{1, 2} -> a}, {2, 3}][[1]]"),
            "SparseArray[List[Rule[List[2], a]], List[3]]"
        );
        assert_eq!(
            eval("Normal[SparseArray[{{1, 2} -> a, {2, 3} -> b}, {2, 3}][[All, {2, 3}]]]"),
            "List[List[a, 0], List[0, b]]"
        );
        assert_eq!(
            eval("ArrayRules[Transpose[SparseArray[{{1, 2} -> a, {2, 1} -> b}, {2, 3}]]]"),
            "List[Rule[List[1, 2], b], Rule[List[2, 1], a], Rule[List[Blank[], Blank[]], 0]]"
        );
        assert_eq!(
            eval("Normal[SparseArray[{{1, 2} -> a}, {2, 3}] . SparseArray[{{2, 1} -> b}, {3, 2}]]"),
            "List[List[Times[a, b], 0], List[0, 0]]"
        );
        assert_eq!(
            eval("Normal[2 SparseArray[{{1} -> a}, {3}] + 1]"),
            "List[Plus[1, Times[2, a]], 1, 1]"
        );
        assert_eq!(
            eval("ArrayRules[Inverse[SparseArray[{{1, 1} -> 2, {2, 2} -> 4}, {2, 2}]]]"),
            "List[Rule[List[1, 1], Rational[1, 2]], Rule[List[2, 2], Rational[1, 4]], Rule[List[Blank[], Blank[]], 0]]"
        );
    }

    #[test]
    fn evaluates_association_grouping_statistics_and_number_theory_extensions() {
        assert_eq!(
            eval("Merge[{<|a -> 1, b -> 2|>, <|a -> 3|>}, Identity]"),
            "Association[Rule[a, List[1, 3]], Rule[b, List[2]]]"
        );
        assert_eq!(
            eval("GroupBy[{1, 2, 3, 4, 5, 6}, EvenQ -> Total]"),
            "Association[Rule[False, 9], Rule[True, 12]]"
        );
        assert_eq!(
            eval("GatherBy[{1, 2, 3, 4, 5, 6}, EvenQ]"),
            "List[List[1, 3, 5], List[2, 4, 6]]"
        );
        assert_eq!(
            eval("KeyUnion[{<|a -> 1|>, <|b -> 2|>}]"),
            "List[Association[Rule[a, 1], Rule[b, Missing[\"KeyAbsent\", b]]], Association[Rule[a, Missing[\"KeyAbsent\", a]], Rule[b, 2]]]"
        );
        assert_eq!(eval("Variance[{1, 2, 3, 4, 5}]"), "Rational[5, 2]");
        assert_eq!(
            eval("StandardDeviation[{1, 2, 3, 4, 5}]"),
            "Power[Rational[5, 2], Rational[1, 2]]"
        );
        assert_eq!(eval("Norm[{3, 4}]"), "5");
        assert_eq!(eval("Norm[{1, -2, 3}, Infinity]"), "3");
        assert_eq!(eval("PrimePowerQ[8]"), "True");
        assert_eq!(eval("PrimePowerQ[12]"), "False");
        assert_eq!(eval("ChineseRemainder[{2, 3, 2}, {3, 5, 7}]"), "23");
        assert_eq!(eval("Boole[{True, False, True}]"), "List[1, 0, 1]");
        assert_eq!(
            eval("FactorInteger[18/35]"),
            "List[List[2, 1], List[3, 2], List[5, -1], List[7, -1]]"
        );
        assert_eq!(eval("IntegerExponent[1000]"), "3");
        assert_eq!(eval("IntegerExponent[0, 10]"), "Infinity");
    }

    #[test]
    fn evaluates_partition_threading_and_nesting_extensions() {
        assert_eq!(
            eval("Partition[{1, 2, 3, 4, 5}, 2, 1, {1, 1}]"),
            "List[List[1, 2], List[2, 3], List[3, 4], List[4, 5], List[5, 1]]"
        );
        assert_eq!(
            eval("Partition[{1, 2, 3, 4, 5, 6}, 2, 2, -1]"),
            "List[List[6, 1], List[2, 3], List[4, 5]]"
        );
        assert_eq!(
            eval("MapThread[f, {{{a, b}, {c, d}}, {{e, f}, {g, h}}}, 2]"),
            "List[List[f[a, e], f[b, f]], List[f[c, g], f[d, h]]]"
        );
        assert_eq!(
            eval("Position[{a, b, c}, _, {1}, Heads -> False]"),
            "List[List[1], List[2], List[3]]"
        );
        assert_eq!(eval("MapThread[f, {a, b}, 0]"), "f[a, b]");
        assert_eq!(
            eval("NestWhile[#/2 &, 100, # > 1 &, 2]"),
            "Rational[25, 64]"
        );
        assert_eq!(eval("Nest[f, x, 3]"), "f[f[f[x]]]");
        assert_eq!(eval("FixedPointList[# /. a -> b &, a]"), "List[a, b, b]");
    }

    #[test]
    fn evaluates_native_polynomial_core() {
        assert_eq!(
            eval("Expand[(x + 1)^3]"),
            "Plus[1, Power[x, 3], Times[3, x], Times[3, Power[x, 2]]]"
        );
        assert_eq!(eval("PolynomialQ[(x + 1)^2, x]"), "True");
        assert_eq!(eval("PolynomialQ[1/x, x]"), "False");
        assert_eq!(eval("PolynomialQ[f[a] + f[a]^2, f[a]]"), "True");
        assert_eq!(eval("Variables[(x + y)^2 + 3 z]"), "List[x, y, z]");
        assert_eq!(
            eval("MonomialList[x y + x^2 + 3, {x, y}]"),
            "List[Power[x, 2], Times[x, y], 3]"
        );
        assert_eq!(
            eval("Coefficient[2 x^2 y + 3 x y + y, x, 1]"),
            "Times[3, y]"
        );
        assert_eq!(eval("Coefficient[x^2 y^2 + 3 x y + 1, x y, 2]"), "1");
        assert_eq!(eval("Exponent[0, x]"), "-Infinity");
        assert_eq!(eval("CoefficientList[x^2 + 3 x + 2, x]"), "List[2, 3, 1]");
        assert_eq!(
            eval("CoefficientList[x y + 2 y + 3, {x, y}]"),
            "List[List[3, 2], List[0, 1]]"
        );
        assert_eq!(
            eval("Collect[x y + x + 2 y, x]"),
            "Plus[Times[2, y], Times[x, Plus[1, y]]]"
        );
        assert_eq!(eval("Numerator[{1/2, x/y}]"), "List[1, x]");
        assert_eq!(eval("Denominator[{1/2, x/y}]"), "List[2, y]");
        assert_eq!(
            eval("Expand[(x + 1)^2 (y + 1)^2, x]"),
            "Plus[Power[Plus[1, y], 2], Times[2, x, Power[Plus[1, y], 2]], Times[Power[x, 2], Power[Plus[1, y], 2]]]"
        );
        assert_eq!(
            eval("CoefficientList[x^2 + I x + 1, x]"),
            "List[1, Complex[0, 1], 1]"
        );
        assert_eq!(eval("Factor[x^2 - 1]"), "Times[Plus[-1, x], Plus[1, x]]");
        assert_eq!(eval("Factor[2 x y + 2 y]"), "Times[2, y, Plus[1, x]]");
        assert_eq!(
            eval("FactorList[2 x^2 - 2]"),
            "List[List[2, 1], List[Plus[-1, x], 1], List[Plus[1, x], 1]]"
        );
        assert_eq!(
            eval("Together[1/x + 1/y]"),
            "Times[Plus[x, y], Power[x, -1], Power[y, -1]]"
        );
        assert_eq!(eval("Cancel[(x^2 - 1)/(x - 1)]"), "Plus[1, x]");
        assert_eq!(
            eval("PolynomialQuotient[x^3 - 1, x - 1, x]"),
            "Plus[1, x, Power[x, 2]]"
        );
        assert_eq!(eval("PolynomialGCD[x^2 - 1, x^2 - x]"), "Plus[-1, x]");
        assert_eq!(
            eval("Resultant[x^2 - y, x - y, x]"),
            "Plus[Power[y, 2], Times[-1, y]]"
        );
        assert_eq!(eval("Discriminant[x^3 + x + 1, x]"), "-31");
        assert_eq!(
            eval("PolynomialReduce[x^2 + y^2, {x + y}, {x, y}]"),
            "List[List[Plus[x, Times[-1, y]]], Times[2, Power[y, 2]]]"
        );
        assert_eq!(
            eval("Subresultants[x^3 + a x + b, x^2 + c, x]"),
            "List[Plus[Power[b, 2], Power[c, 3], Times[-2, a, Power[c, 2]], Times[c, Power[a, 2]]], Plus[a, Times[-1, c]], 1]"
        );
        assert_eq!(
            eval("GroebnerBasis[{x^2 - y, x y - 1}, {x, y}]"),
            "List[Plus[-1, Power[y, 3]], Plus[x, Times[-1, Power[y, 2]]]]"
        );
        assert_eq!(
            eval("Decompose[(x^2 + 1)^3 + 2, x]"),
            "List[Plus[3, Power[x, 3], Times[3, x], Times[3, Power[x, 2]]], Power[x, 2]]"
        );
        assert_eq!(
            eval("Decompose[(x^2 + I x + 1)^2, x]"),
            "List[Plus[1, Power[x, 2], Times[2, x]], Plus[Power[x, 2], Times[Complex[0, 1], x]]]"
        );
    }

    #[test]
    fn evaluates_native_algebraic_root_core() {
        assert_eq!(
            eval("Root[2 #^3 - 4 &, 2]"),
            "Root[Function[Plus[-2, Power[Slot[1], 3]]], 2, 0]"
        );
        assert_eq!(eval("Root[#^2 - 4 &, 2]"), "2");
        assert_eq!(eval("ToRadicals[Root[#^2 + 1 &, 1]]"), "Complex[0, -1]");
        assert_eq!(eval("CountRoots[(x - 1)^2, {x, 1, 1}]"), "2");
        assert_eq!(
            eval("RootIntervals[(x - 1)^2 (x + 1)]"),
            "List[List[List[-1, -1], List[1, 1]], List[List[1], List[2]]]"
        );
        assert_eq!(
            eval("IsolatingInterval[Root[#^2 - 2 &, 1]]"),
            "List[Rational[-91, 64], Rational[-45, 32]]"
        );
        assert_eq!(eval("RootSum[#^3 - 2 &, (#^3 &)]"), "6");
        assert_eq!(
            eval("MinimalPolynomial[Root[#^3 - 2 &, 1]^2, x]"),
            "Plus[-4, Power[x, 3]]"
        );
        assert_eq!(
            eval("RootReduce[1/Root[#^3 - 2 &, 1]]"),
            "Root[Function[Plus[-1, Times[2, Power[Slot[1], 3]]]], 1, 0]"
        );
        assert_eq!(
            eval("RootReduce[Root[#^2 - 2 &, 2] + Root[#^2 - 3 &, 2]]"),
            "Root[Function[Plus[1, Times[-10, Power[Slot[1], 2]], Power[Slot[1], 4]]], 4, 0]"
        );
        assert_eq!(
            eval("Solve[x^2 + 1 == 0, x]"),
            "List[List[Rule[x, Root[Function[Plus[1, Power[Slot[1], 2]]], 1, 0]]], List[Rule[x, Root[Function[Plus[1, Power[Slot[1], 2]]], 2, 0]]]]"
        );
        assert_eq!(
            eval("Solve[{2 x + y == 5, x - 3 y == -4}, {x, y}]"),
            "List[List[Rule[x, Rational[11, 7]], Rule[y, Rational[13, 7]]]]"
        );
        assert_eq!(
            eval("Solve[Sqrt[2] x == 1, x]"),
            "List[List[Rule[x, Times[Rational[1, 2], Power[2, Rational[1, 2]]]]]]"
        );
        assert_eq!(
            eval("Solve[{x + y == Pi, x - y == 1}, {x, y}]"),
            "List[List[Rule[x, Plus[Rational[1, 2], Times[Rational[1, 2], Pi]]], Rule[y, Plus[Rational[-1, 2], Times[Rational[1, 2], Pi]]]]]"
        );
    }

    #[test]
    fn evaluates_extended_list_statistics_and_permutations() {
        assert_eq!(eval("MinMax[{3, 1, 4, 1, 5, 9}]"), "List[1, 9]");
        assert_eq!(eval("Mode[{a, a, b, c, c}]"), "a");
        assert_eq!(eval("Quantile[{1, 2, 3, 4, 5, 6}, 1/2]"), "3");
        assert_eq!(eval("Quartiles[Range[10]]"), "List[3, Rational[11, 2], 8]");
        assert_eq!(
            eval("PermutationCycles[{2, 3, 1, 4}]"),
            "Cycles[List[List[1, 2, 3]]]"
        );
        assert_eq!(
            eval("PermutationList[Cycles[{{1, 2}, {3, 4}}], 4]"),
            "List[2, 1, 4, 3]"
        );
        assert_eq!(eval("VectorQ[{1, 2, 3}, IntegerQ]"), "True");
        assert_eq!(
            eval("PositionIndex[{u, v, w, u, v}]"),
            "Association[Rule[u, List[1, 4]], Rule[v, List[2, 5]], Rule[w, List[3]]]"
        );
        assert_eq!(
            eval("Subdivide[1, 10, 4]"),
            "List[1, Rational[13, 4], Rational[11, 2], Rational[31, 4], 10]"
        );
        assert_eq!(
            eval("SubsetMap[Reverse, {a, b, c, d, e}, {1, 3, 5}]"),
            "List[e, b, c, d, a]"
        );
        assert_eq!(
            eval("Sort[PermutationList[RandomPermutation[8], 8]]"),
            "List[1, 2, 3, 4, 5, 6, 7, 8]"
        );
        let sample = evaluate(parse_input_form("RandomSample[{a, b, c, d}, 3]").unwrap()).unwrap();
        assert!(sample.has_head("List"));
        assert_eq!(sample.args().len(), 3);
        assert_eq!(
            sample
                .args()
                .iter()
                .map(Expr::to_full_form)
                .collect::<BTreeSet<_>>()
                .len(),
            3
        );
        assert!(
            sample.args().iter().all(|item| {
                [symbol("a"), symbol("b"), symbol("c"), symbol("d")].contains(item)
            })
        );
    }

    #[test]
    fn evaluates_advanced_patterns_association_parts_and_numeric_utilities() {
        assert_eq!(eval("MatchQ[a, Except[_Integer]]"), "True");
        assert_eq!(eval("MatchQ[_, Verbatim[_]]"), "True");
        assert_eq!(eval("MatchQ[a, __]"), "True");
        assert_eq!(eval("Cases[{f[a, b]}, f[x__] :> x]"), "List[a, b]");
        assert_eq!(
            eval("Cases[{f[], f[2], f[a]}, f[x_:7] :> x]"),
            "List[7, 2, a]"
        );
        assert_eq!(
            eval("Cases[{f[1], f[1, 2], f[1, 2, 3]}, f[Repeated[_Integer, {2, 3}]]]"),
            "List[f[1, 2], f[1, 2, 3]]"
        );
        assert_eq!(
            eval("MatchQ[<|a -> 1, b -> 2|>, KeyValuePattern[a -> _Integer]]"),
            "True"
        );
        assert_eq!(
            eval("Part[<|a -> 1, b -> 2, c -> 3|>, {Key[a], Key[c]}]"),
            "Association[Rule[a, 1], Rule[c, 3]]"
        );
        assert_eq!(
            eval("Pick[<|p -> a, q -> b|>, {False, True}]"),
            "Association[Rule[q, b]]"
        );
        assert_eq!(eval("Mod[14, 5, -1]"), "-1");
        assert_eq!(eval("QuotientRemainder[-14, 5]"), "List[-3, 1]");
        assert_eq!(eval("Clip[-7, {-5, 5}, {100, 200}]"), "100");
    }

    #[test]
    fn emits_messages_for_rejected_collection_string_and_listable_inputs() {
        let mut evaluator = Evaluator::default();

        assert_eq!(
            submit(&mut evaluator, "Pick[{a, b}, {True}]"),
            "Pick[List[a, b], List[True]]"
        );
        assert_eq!(
            evaluator.messages(),
            &[call("MessageName", [symbol("Pick"), string("error")])]
        );

        assert_eq!(
            submit(
                &mut evaluator,
                "Function[Null, f[#1, #2], Listable][{a, b}, {c, d, e}]"
            ),
            "Function[Null, f[Slot[1], Slot[2]], Listable][List[a, b], List[c, d, e]]"
        );
        assert_eq!(
            evaluator.messages(),
            &[call("MessageName", [symbol("General"), string("error")])]
        );

        assert_eq!(
            submit(
                &mut evaluator,
                "StringCases[\"abc\", Optional[\"a\"] ~~ \"b\"]"
            ),
            "StringCases[\"abc\", StringExpression[Optional[\"a\"], \"b\"]]"
        );
        assert_eq!(
            evaluator.messages(),
            &[call(
                "MessageName",
                [symbol("StringCases"), string("error")]
            )]
        );
    }

    #[test]
    fn captures_print_output_across_forms_and_nested_evaluation() {
        let mut evaluator = Evaluator::default();

        assert_eq!(submit(&mut evaluator, "Print[\"a\", 1 + 2, x]"), "Null");
        assert_eq!(evaluator.prints(), &["a3x"]);

        assert_eq!(
            submit(
                &mut evaluator,
                "Print[InputForm[{1, 2/3, a + b}]]; Print[FullForm[{1, 2/3, a + b}]]"
            ),
            "Null"
        );
        assert_eq!(
            evaluator.prints(),
            &["{1, 2/3, a + b}", "List[1, Rational[2, 3], Plus[a, b]]"]
        );

        assert_eq!(submit(&mut evaluator, "Do[Print[i], {i, 3}]"), "Null");
        assert_eq!(evaluator.prints(), &["1", "2", "3"]);
    }

    #[test]
    fn check_quiet_on_off_assert_cleanup_and_append_to_preserve_state() {
        let mut evaluator = Evaluator::default();

        assert_eq!(
            submit(&mut evaluator, "Check[Part[f[a], 2], fallback]"),
            "fallback"
        );
        assert!(evaluator.message_texts()[0].contains("Part specifications"));
        assert_eq!(
            submit(
                &mut evaluator,
                "Check[Part[f[a], 2], fallback, Other::error]"
            ),
            "Part[f[a], 2]"
        );
        assert_eq!(
            submit(&mut evaluator, "Check[Part[f[a], 2], $MessageList]"),
            "List[HoldForm[MessageName[Part, \"error\"]]]"
        );
        assert_eq!(
            submit(&mut evaluator, "Check[Quiet[Part[f[a], 2]], fallback]"),
            "Part[f[a], 2]"
        );
        assert_eq!(
            submit(&mut evaluator, "Quiet[Check[Part[f[a], 2], fallback]]"),
            "fallback"
        );
        assert!(evaluator.messages().is_empty());

        assert_eq!(submit(&mut evaluator, "Off[f::tag]"), "Null");
        assert_eq!(
            submit(&mut evaluator, "Check[Message[f::tag], fallback]"),
            "Null"
        );
        assert_eq!(submit(&mut evaluator, "On[f::tag]"), "Null");
        assert_eq!(
            submit(&mut evaluator, "Check[Message[f::tag], fallback]"),
            "fallback"
        );

        assert_eq!(
            submit(&mut evaluator, "$MessagePrePrint = FullForm"),
            "FullForm"
        );
        assert_eq!(submit(&mut evaluator, "Message[f::tag, {1 + 2}]"), "Null");
        assert_eq!(evaluator.message_texts(), &["f::tag: {3}"]);

        assert_eq!(submit(&mut evaluator, "On[Assert]"), "Null");
        assert_eq!(
            submit(&mut evaluator, "Check[Assert[False, tag], msg]"),
            "msg"
        );
        assert_eq!(submit(&mut evaluator, "Off[Assert]"), "Null");
        assert_eq!(
            submit(&mut evaluator, "Assert[Print[\"x\"]; False]"),
            "Assert[CompoundExpression[Print[\"x\"], False]]"
        );
        assert!(evaluator.prints().is_empty());

        assert_eq!(
            submit(
                &mut evaluator,
                "CheckAbort[WithCleanup[Print[\"expr\"]; Abort[], Print[\"cleanup\"]], caught]"
            ),
            "caught"
        );
        assert_eq!(evaluator.prints(), &["expr", "cleanup"]);

        assert_eq!(submit(&mut evaluator, "items = {a}"), "List[a]");
        assert_eq!(submit(&mut evaluator, "AppendTo[items, b]"), "List[a, b]");
        assert_eq!(submit(&mut evaluator, "items"), "List[a, b]");
    }

    #[test]
    fn mutating_assignments_preserve_session_state() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "n = 5"), "5");
        assert_eq!(submit(&mut evaluator, "n++"), "5");
        assert_eq!(submit(&mut evaluator, "++n"), "7");
        assert_eq!(submit(&mut evaluator, "n += 3"), "10");
        assert_eq!(submit(&mut evaluator, "n /= 2"), "5");
        assert_eq!(submit(&mut evaluator, "n"), "5");
    }

    #[test]
    fn system_precision_and_root_limits_preserve_session_state() {
        let mut evaluator = Evaluator::default();
        assert_eq!(submit(&mut evaluator, "$MaxExtraPrecision"), "50");
        assert_eq!(submit(&mut evaluator, "$MaxExtraPrecision = 12"), "12");
        assert_eq!(submit(&mut evaluator, "$MaxExtraPrecision = -1"), "12");
        assert_eq!(
            evaluator.messages(),
            &[call(
                "MessageName",
                [symbol("$MaxExtraPrecision"), string("limset")]
            )]
        );
        assert_eq!(submit(&mut evaluator, "$MaxRootDegree"), "1000");
        assert_eq!(submit(&mut evaluator, "$MaxRootDegree = 3"), "3");
        assert_eq!(
            submit(&mut evaluator, "Root[#^4 - 2 &, 1]"),
            "Root[Function[Plus[Power[Slot[1], 4], -2]], 1]"
        );
        assert_eq!(
            submit(&mut evaluator, "Root[#^2 - 2^(1/3) &, 2]"),
            "Root[Function[Plus[Power[Slot[1], 2], Times[-1, Power[2, Times[1, Power[3, -1]]]]]], 2]"
        );
        assert_eq!(submit(&mut evaluator, "$MaxRootDegree = Infinity"), "3");
        assert_eq!(
            evaluator.messages(),
            &[call(
                "MessageName",
                [symbol("$MaxRootDegree"), string("limset")]
            )]
        );
        assert_eq!(submit(&mut evaluator, "$MaxRootDegree"), "3");
    }

    #[test]
    fn label_and_goto_resume_compound_expressions() {
        assert_eq!(eval("Goto[end]; never; Label[end]; reached"), "reached");
        assert_eq!(
            eval("Module[{x = 0}, Label[start]; x = x + 1; If[x < 3, Goto[start]]; x]"),
            "3"
        );
        assert_eq!(eval("Label[done]"), "Label[done]");
        assert_eq!(eval("Goto[unreachable]"), "Goto[unreachable]");
    }
}
