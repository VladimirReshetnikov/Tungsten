from __future__ import annotations

# Transitional evaluator-dispatch module. The concrete built-in implementations
# still live in tungsten.expression; this module isolates the very large
# single-step dispatch table so parser, runtime-loop, and function-family work
# no longer contend for the same physical file.
from . import expression as _runtime

# The extracted dispatch body intentionally keeps its original helper names.
# Loading happens lazily from expression._evaluate after tungsten.expression has
# finished defining those helpers, so this is acyclic in normal package imports.
globals().update(
    {name: getattr(_runtime, name) for name in dir(_runtime) if not name.startswith("__")}
)

def evaluate_once(expr: Expr) -> Expr:
    if isinstance(expr, Symbol):
        try:
            record = _SYMBOL_REGISTRY.ensure_name(expr.name)
        except WolframEvaluationError:
            return expr
        if record.full_name == "System`$Context":
            return string(_SYMBOL_REGISTRY.current_context)
        if record.full_name == "System`$ContextPath":
            return _evaluated_list_expr(*(string(context) for context in _SYMBOL_REGISTRY.context_path))
        if record.full_name == "System`$Line":
            session = _active_evaluation_session()
            if session is not None:
                return integer(session.line)
        if record.full_name == "System`$MessageList":
            return current_message_list_expr()
        if record.full_name == "System`$MachinePrecision":
            return _machine_real(sys.float_info.mant_dig * math.log10(2))
        if record.full_name == "System`$MaxMachineNumber":
            return _machine_real(sys.float_info.max)
        if record.full_name == "System`$MinMachineNumber":
            return _machine_real(float.fromhex("0x1.0000000000000p-1022"))
        if record.full_name == "System`$MachineEpsilon":
            return _machine_real(sys.float_info.epsilon)
        if record.full_name in {"System`Exit", "System`Quit"} and _active_evaluation_session() is not None:
            raise TungstenExitRequested(0)
        if record.full_name == "System`I":
            return ComplexNumber(integer(0), integer(1))
        if record.own_value is not None:
            active_symbols = _ACTIVE_OWN_VALUE_SYMBOLS.get()
            if record.full_name in active_symbols:
                return expr
            token = _ACTIVE_OWN_VALUE_SYMBOLS.set(active_symbols + (record.full_name,))
            try:
                return _evaluate_iteration_continuation(record.own_value)
            finally:
                _ACTIVE_OWN_VALUE_SYMBOLS.reset(token)
        return expr

    if isinstance(expr, (Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String)):
        return expr

    if not isinstance(expr, Call):
        return expr

    if isinstance(expr.head_expr, Symbol):
        raw_head_name = _system_dispatch_name(expr.head_expr)

        if raw_head_name in {"Exit", "Quit"} and _active_evaluation_session() is not None:
            exit_expr(expr.arguments)

        if raw_head_name == "Abort":
            return abort_expr(expr.arguments)

        if raw_head_name == "CheckAbort":
            return check_abort_expr(expr.arguments)

        if raw_head_name == "AbortProtect":
            return abort_protect_expr(expr.arguments)

        if raw_head_name == "Throw":
            throw_expr(expr.arguments)

        if raw_head_name == "Catch":
            return catch_expr(expr.arguments)

        if raw_head_name == "Check":
            return check_expr(expr.arguments)

        if raw_head_name == "Enclose":
            return enclose_expr(expr.arguments)

        if raw_head_name == "Confirm":
            return confirm_expr(expr.arguments)

        if raw_head_name == "ConfirmBy":
            return confirm_by_expr(expr.arguments)

        if raw_head_name == "ConfirmMatch":
            return confirm_match_expr(expr.arguments)

        if raw_head_name == "ConfirmAssert":
            return confirm_assert_expr(expr.arguments)

        if raw_head_name == "Assert":
            return assert_expr(expr.arguments)

        if raw_head_name == "WithCleanup":
            return with_cleanup_expr(expr.arguments)

        if raw_head_name == "With":
            from .expression_scoping import with_expr
            return with_expr(expr.arguments)

        if raw_head_name == "Module":
            from .expression_scoping import module_expr
            return module_expr(expr.arguments)

        if raw_head_name == "Block":
            from .expression_scoping import block_expr
            return block_expr(expr.arguments)

        if raw_head_name in {"InheritedBlock", "Internal`InheritedBlock"}:
            # Wolfram puts ``InheritedBlock`` in the ``Internal``` context;
            # accept both the qualified and unqualified spelling so the
            # kernel-style ``Internal``InheritedBlock`` and the ergonomic
            # short name dispatch identically.
            from .expression_scoping import inherited_block_expr
            return inherited_block_expr(expr.arguments)

        if raw_head_name == "Table":
            # ``Table`` is HoldAll on its iterator specs and body; dispatch
            # before argument evaluation so the iterator variable is not
            # resolved to its outer value before Table can Block-scope it.
            from .expression_iteration import table_expr
            return table_expr(expr.arguments)

        if raw_head_name == "Do":
            from .expression_iteration import do_expr
            return do_expr(expr.arguments)

        if raw_head_name == "Sum":
            # ``Sum`` is HoldAll on its iter specs and body so the iter
            # variable is not looked up before Block-scoping installs
            # the per-iteration value, matching the kernel's behavior.
            from .expression_iteration import sum_expr
            return sum_expr(expr.arguments)

        if raw_head_name == "Product":
            from .expression_iteration import product_expr
            return product_expr(expr.arguments)

        if raw_head_name == "For":
            # ``For`` is HoldAll: init / test / incr / body all need
            # to be re-evaluated each iteration, so we dispatch with
            # the raw arguments before the standard arg-eval pass.
            from .expression_iteration import for_expr
            return for_expr(expr.arguments)

        if raw_head_name == "While":
            from .expression_iteration import while_expr
            return while_expr(expr.arguments)

        if raw_head_name == "Break":
            return break_expr(expr.arguments)

        if raw_head_name == "Continue":
            return continue_expr(expr.arguments)

        if raw_head_name == "Return":
            return return_expr(expr.arguments)

        if raw_head_name == "Label":
            # ``Label`` is HoldAll: its argument is a tag, not an
            # expression to be evaluated. Dispatch before the
            # standard arg-eval pass so the original tag expression
            # is preserved for the goto-scan in CompoundExpression.
            return label_expr(expr.arguments)

        if raw_head_name == "Goto":
            return goto_expr(expr.arguments)

        if raw_head_name == "Increment":
            # ``Increment`` / ``Decrement`` / ``PreIncrement`` /
            # ``PreDecrement`` are HoldFirst — the target symbol must
            # not be looked up as a value before we can mutate it.
            return increment_expr(expr.arguments)

        if raw_head_name == "Decrement":
            return decrement_expr(expr.arguments)

        if raw_head_name == "PreIncrement":
            return pre_increment_expr(expr.arguments)

        if raw_head_name == "PreDecrement":
            return pre_decrement_expr(expr.arguments)

        if raw_head_name == "TimeConstrained":
            return time_constrained_expr(expr.arguments)

        if raw_head_name == "TimeRemaining":
            return time_remaining_expr(expr.arguments)

        if raw_head_name == "AbsoluteTiming":
            return absolute_timing_expr(expr.arguments)

        if raw_head_name == "Pause":
            return pause_expr(expr.arguments)

        if raw_head_name == "Reap":
            return reap_expr(expr.arguments)

        if raw_head_name == "Sow":
            return sow_expr(expr.arguments)

        if raw_head_name == "Failsafe":
            return failsafe_expr(expr.arguments)

        if raw_head_name == "Quiet":
            return quiet_expr(expr.arguments)

        if raw_head_name == "Message":
            return message_expr(expr.arguments)

        if raw_head_name == "Off":
            return off_expr(expr.arguments)

        if raw_head_name == "On":
            return on_expr(expr.arguments)

        if raw_head_name == "Print":
            return print_expr(expr.arguments)

        if raw_head_name == "MessageList":
            return message_list_expr(expr.arguments)

        if raw_head_name in {"And", "Or"}:
            return _evaluate_held_boolean_logic(expr.head_expr, expr.arguments)

        if raw_head_name == "CompoundExpression":
            return compound_expression_expr(expr.arguments)

        if raw_head_name == "Set":
            return set_expr(expr.arguments)

        if raw_head_name == "SetDelayed":
            return set_delayed_expr(expr.arguments)

        if raw_head_name == "AppendTo":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("AppendTo expects exactly two arguments.")
            current = evaluate(expr.arguments[0])
            appended = append(current, evaluate(expr.arguments[1]))
            return set_expr((expr.arguments[0], appended))

        if raw_head_name == "TagSet":
            return tag_set_expr(expr.arguments, delayed=False)

        if raw_head_name == "TagSetDelayed":
            return tag_set_expr(expr.arguments, delayed=True)

        if raw_head_name == "Unset":
            return unset_expr(expr.arguments)

        if raw_head_name == "TagUnset":
            return tag_unset_expr(expr.arguments)

        if raw_head_name == "Clear":
            return clear_expr(expr.arguments)

        if raw_head_name == "ClearAll":
            return clear_all_expr(expr.arguments)

        if raw_head_name == "SetAttributes":
            return set_attributes_expr(expr.arguments)

        if raw_head_name == "ClearAttributes":
            return clear_attributes_expr(expr.arguments)

        if raw_head_name == "Protect":
            return protect_expr(expr.arguments, protect=True)

        if raw_head_name == "Unprotect":
            return protect_expr(expr.arguments, protect=False)

        if raw_head_name in {"In", "InString", "Out"}:
            return history_expr(raw_head_name, expr.arguments)

        if raw_head_name == "DownValues":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("DownValues expects exactly one symbol.")
            return down_values_expr(expr.arguments[0])

        if raw_head_name == "UpValues":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("UpValues expects exactly one symbol.")
            return up_values_expr(expr.arguments[0])

        if raw_head_name == "SubValues":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("SubValues expects exactly one symbol.")
            return sub_values_expr(expr.arguments[0])

        if raw_head_name == "NValues":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("NValues expects exactly one symbol.")
            return n_values_expr(expr.arguments[0])

        if raw_head_name == "OwnValues":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("OwnValues expects exactly one symbol or symbol-name string.")
            return own_values_expr(expr.arguments[0])

        if raw_head_name == "Attributes":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("Attributes expects exactly one symbol, string name, or list argument.")
            return attributes_expr(expr.arguments[0])

        if raw_head_name == "Evaluate":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("Evaluate expects exactly one argument.")
            return _evaluate_evaluate_payload(expr.arguments[0])

        if raw_head_name == "Inactive":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("Inactive expects exactly one argument.")
            held_arguments = _normalize_held_arguments_for_head(raw_head_name, expr.arguments)
            if len(held_arguments) != 1:
                raise WolframEvaluationError("Inactive expects exactly one argument after Sequence splicing.")
            target = held_arguments[0]
            if isinstance(target, (Integer, Real, RationalNumber, ComplexNumber, SpecialReal, String, ByteArrayExpr)):
                return target
            return Call(head_expr=expr.head_expr, arguments=(target,))

        if raw_head_name in _HELD_ARGUMENT_HEADS:
            held_arguments = _normalize_held_arguments_for_head(raw_head_name, expr.arguments)

            if raw_head_name == "Function" and len(held_arguments) not in {1, 2, 3}:
                raise WolframEvaluationError("Function expects one, two, or three arguments.")

            return Call(head_expr=expr.head_expr, arguments=held_arguments)

        if raw_head_name == "ReleaseHold":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("ReleaseHold expects exactly one argument.")
            return release_hold(evaluate(expr.arguments[0]))

        if raw_head_name == "Activate":
            if len(expr.arguments) == 1:
                return activate_expr(evaluate(expr.arguments[0]))
            if len(expr.arguments) == 2:
                return activate_expr(evaluate(expr.arguments[0]), evaluate(expr.arguments[1]))
            raise WolframEvaluationError("Activate expects an expression and an optional pattern.")

        if raw_head_name == "ValueQ":
            if len(expr.arguments) != 1:
                raise WolframEvaluationError("ValueQ expects exactly one argument.")
            return value_q_expr(expr.arguments[0])

        if raw_head_name == "MakeBoxes":
            if len(expr.arguments) == 1:
                return make_boxes_expr(expr.arguments[0])
            if len(expr.arguments) == 2:
                return make_boxes_expr(expr.arguments[0], evaluate(expr.arguments[1]))
            raise WolframEvaluationError("MakeBoxes expects an expression and an optional form.")

        if raw_head_name == "MakeExpression":
            if len(expr.arguments) == 1:
                return make_expression_expr(expr.arguments[0])
            if len(expr.arguments) == 2:
                return make_expression_expr(expr.arguments[0], evaluate(expr.arguments[1]))
            raise WolframEvaluationError("MakeExpression expects boxes and an optional form.")

        if raw_head_name == "MatchQ":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("MatchQ expects exactly two arguments.")
            return match_q(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])

        if raw_head_name == "FreeQ":
            if len(expr.arguments) == 2:
                return free_q(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return free_q(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError("FreeQ expects an expression, a pattern, and an optional level specification.")

        if raw_head_name == "Cases":
            # Strip an optional ``Heads -> True/False`` rule from the
            # tail so ``Cases[expr, patt, level, Heads -> True]`` works.
            cases_args = list(expr.arguments)
            cases_include_heads = False
            if cases_args and _is_heads_option_rule(cases_args[-1]):
                heads_rule = cases_args[-1]
                cases_args = cases_args[:-1]
                assert isinstance(heads_rule, Call)
                cases_include_heads = isinstance(heads_rule.arguments[1], Symbol) and heads_rule.arguments[1].name == "True"
            if len(cases_args) == 2:
                return cases(
                    _evaluate_transparent_argument(cases_args[0]),
                    cases_args[1],
                    include_heads=cases_include_heads,
                )
            if len(cases_args) == 3:
                return cases(
                    _evaluate_transparent_argument(cases_args[0]),
                    cases_args[1],
                    evaluate(cases_args[2]),
                    include_heads=cases_include_heads,
                )
            if len(cases_args) == 4:
                return cases(
                    _evaluate_transparent_argument(cases_args[0]),
                    cases_args[1],
                    evaluate(cases_args[2]),
                    evaluate(cases_args[3]),
                    include_heads=cases_include_heads,
                )
            raise WolframEvaluationError(
                "Cases expects an expression, a pattern or transformation rule, and optional level and match limits."
            )

        if raw_head_name == "DeleteCases":
            if len(expr.arguments) == 2:
                return delete_cases(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return delete_cases(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            if len(expr.arguments) == 4:
                return delete_cases(
                    _evaluate_transparent_argument(expr.arguments[0]),
                    expr.arguments[1],
                    evaluate(expr.arguments[2]),
                    evaluate(expr.arguments[3]),
                )
            raise WolframEvaluationError(
                "DeleteCases expects an expression, a pattern, and optional level and match limits."
            )

        if raw_head_name == "Replace":
            if len(expr.arguments) == 2:
                return replace(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return replace(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError(
                "Replace expects an expression, replacement rules, and an optional level specification."
            )

        if raw_head_name == "ReplaceAll":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("ReplaceAll expects exactly two arguments.")
            return replace_all(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])

        if raw_head_name == "ReplaceRepeated":
            if len(expr.arguments) != 2:
                raise WolframEvaluationError("ReplaceRepeated expects exactly two arguments.")
            return replace_repeated(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])

        if raw_head_name == "ReplaceAt":
            if len(expr.arguments) != 3:
                raise WolframEvaluationError("ReplaceAt expects exactly three arguments.")
            return replace_at(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))

        if raw_head_name == "StringCases":
            if len(expr.arguments) == 2:
                return string_cases(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return string_cases(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError("StringCases expects a string, a pattern or rule, and an optional match limit.")

        if raw_head_name == "StringReplace":
            if len(expr.arguments) == 2:
                return string_replace(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1])
            if len(expr.arguments) == 3:
                return string_replace(_evaluate_transparent_argument(expr.arguments[0]), expr.arguments[1], evaluate(expr.arguments[2]))
            raise WolframEvaluationError("StringReplace expects a string, rules, and an optional replacement limit.")

        if raw_head_name == "Select":
            if len(expr.arguments) == 1:
                return call("Function", call("Select", call("Slot"), evaluate(expr.arguments[0])))

        if raw_head_name == "Discard":
            if len(expr.arguments) == 1:
                return call("Function", call("Discard", call("Slot"), evaluate(expr.arguments[0])))

        if raw_head_name == "SelectFirst":
            if len(expr.arguments) == 1:
                return call("Function", call("SelectFirst", call("Slot"), evaluate(expr.arguments[0])))

        if raw_head_name == "If":
            return if_expr(expr.arguments)

        if raw_head_name == "Which":
            return which_expr(expr.arguments)

        if raw_head_name == "Switch":
            return switch_expr(expr.arguments)

        if raw_head_name == "Piecewise":
            return piecewise_expr(expr.arguments)

        if raw_head_name == "Pick":
            if len(expr.arguments) == 2:
                return pick(_evaluate_transparent_argument(expr.arguments[0]), _evaluate_transparent_argument(expr.arguments[1]))
            if len(expr.arguments) == 3:
                return pick(
                    _evaluate_transparent_argument(expr.arguments[0]),
                    _evaluate_transparent_argument(expr.arguments[1]),
                    expr.arguments[2],
                )
            raise WolframEvaluationError("Pick expects a data expression, a selector expression, and an optional pattern.")

    evaluated_head = evaluate(expr.head_expr)
    if isinstance(evaluated_head, Symbol) and _system_dispatch_name(evaluated_head) == "Nothing":
        tuple(evaluate(argument) for argument in expr.arguments)
        return symbol("Nothing")

    if _is_callable_expr(evaluated_head):
        if _is_pure_function_expr(evaluated_head):
            evaluated_arguments = _prepare_pure_function_arguments(evaluated_head, expr.arguments)
        else:
            evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        return _apply_callable(evaluated_head, evaluated_arguments)
    if _is_function_expr(evaluated_head):
        raise WolframEvaluationError("Unsupported Function parameter specification.")

    association_head_entries = _association_entries(evaluated_head)
    if association_head_entries is not None:
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        if len(evaluated_arguments) == 1:
            return lookup(evaluated_head, evaluated_arguments[0])
        return Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    if _is_failure_expr(evaluated_head):
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        if len(evaluated_arguments) == 1:
            return failure_property(evaluated_head, evaluated_arguments[0])
        return Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    if isinstance(evaluated_head, SparseArrayExpr):
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        if len(evaluated_arguments) == 1:
            return sparse_array_property(evaluated_head, evaluated_arguments[0])
        return Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    if not isinstance(evaluated_head, Symbol):
        evaluated_arguments = _splice_sequence_arguments(tuple(evaluate(argument) for argument in expr.arguments))
        evaluated_expr = Call(head_expr=evaluated_head, arguments=evaluated_arguments)
        up_value_result = _apply_up_value_definitions(evaluated_expr)
        if up_value_result is not None:
            return up_value_result
        sub_value_result = _apply_sub_value_definitions(evaluated_expr)
        if sub_value_result is not None:
            return sub_value_result
        return evaluated_expr

    evaluated_head_name = _system_dispatch_name(evaluated_head)
    evaluated_arguments = _prepare_symbol_call_arguments(evaluated_head, expr.arguments)
    evaluated_arguments = _normalize_attribute_call(evaluated_head, evaluated_arguments)
    if evaluated_head_name in _UNEVALUATED_TRANSPARENT_HEADS:
        evaluated_arguments = _strip_unevaluated_arguments(evaluated_arguments)
    evaluated_expr = Call(head_expr=evaluated_head, arguments=evaluated_arguments)

    listable_result = _thread_listable_symbol_call(evaluated_head, evaluated_arguments)
    if listable_result is not None:
        return listable_result

    if "HoldAllComplete" not in _attribute_names_for_symbol(evaluated_head):
        up_value_result = _apply_up_value_definitions(evaluated_expr)
        if up_value_result is not None:
            return up_value_result

    down_value_result = _apply_down_value_definitions(evaluated_head, evaluated_expr)
    if down_value_result is not None:
        return down_value_result

    sparse_arithmetic_result = evaluate_sparse_array_arithmetic(evaluated_expr)
    if sparse_arithmetic_result is not None:
        return sparse_arithmetic_result

    constructor_result = _evaluate_numeric_constructor(evaluated_expr)
    if constructor_result is not None:
        return constructor_result

    algebraic_result = _evaluate_algebraic_functions(evaluated_expr)
    if algebraic_result is not None:
        return algebraic_result

    arithmetic_result = _evaluate_numeric_arithmetic(evaluated_expr)
    if arithmetic_result is not None:
        return arithmetic_result

    relation_result = _evaluate_numeric_relation(evaluated_expr)
    if relation_result is not None:
        return relation_result

    arithmetic_result = _evaluate_integer_arithmetic(evaluated_expr)
    if arithmetic_result is not None:
        return arithmetic_result

    relation_result = _evaluate_integer_relation(evaluated_expr)
    if relation_result is not None:
        return relation_result

    inequality_result = _evaluate_inequality(evaluated_expr)
    if inequality_result is not None:
        return inequality_result

    boolean_result = _evaluate_boolean_logic(evaluated_expr)
    if boolean_result is not None:
        return boolean_result

    predicate_result = _evaluate_simple_predicates(evaluated_expr)
    if predicate_result is not None:
        return predicate_result

    integer_special_result = _evaluate_numeric_special_functions(evaluated_expr)
    if integer_special_result is not None:
        return integer_special_result

    integer_special_result = _evaluate_integer_special_functions(evaluated_expr)
    if integer_special_result is not None:
        return integer_special_result

    polynomial_result = _evaluate_polynomial_functions(evaluated_expr)
    if polynomial_result is not None:
        return polynomial_result

    if evaluated_head.name == "ByteArray":
        return byte_array(evaluated_arguments)

    if evaluated_head.name == "SparseArray":
        return sparse_array(*evaluated_arguments)

    if evaluated_head.name == "Identity":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Identity expects exactly one argument.")
        return evaluated_arguments[0]

    if evaluated_head_name == "Symbol":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Symbol expects exactly one string argument.")
        return symbol_expr(evaluated_arguments[0])

    if evaluated_head_name == "SymbolName":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("SymbolName expects exactly one argument.")
        return symbol_name_expr(evaluated_arguments[0])

    if evaluated_head_name == "Unique":
        if len(evaluated_arguments) == 0:
            return unique_expr()
        if len(evaluated_arguments) == 1:
            return unique_expr(evaluated_arguments[0])
        raise WolframEvaluationError("Unique currently expects zero arguments or one symbol, string, or list argument.")

    if evaluated_head_name == "Names":
        if len(evaluated_arguments) == 0:
            return names_expr()
        if len(evaluated_arguments) == 1:
            return names_expr(evaluated_arguments[0])
        raise WolframEvaluationError("Names expects zero arguments or one string pattern/list of string patterns.")

    if evaluated_head_name == "NameQ":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("NameQ expects exactly one string pattern.")
        return name_q_expr(evaluated_arguments[0])

    if evaluated_head_name == "Contexts":
        if len(evaluated_arguments) == 0:
            return contexts_expr()
        if len(evaluated_arguments) == 1:
            return contexts_expr(evaluated_arguments[0])
        raise WolframEvaluationError("Contexts expects zero arguments or one string pattern.")

    if evaluated_head_name == "Context":
        if len(evaluated_arguments) == 0:
            return context_expr()
        if len(evaluated_arguments) == 1:
            return context_expr(evaluated_arguments[0])
        raise WolframEvaluationError("Context expects zero arguments or one symbol/name argument.")

    if evaluated_head_name == "ToString":
        to_string_arguments, to_string_options = _split_trailing_option_rules(evaluated_arguments)
        if len(to_string_arguments) == 1:
            return to_string_expr(to_string_arguments[0], options=to_string_options)
        if len(to_string_arguments) == 2:
            return to_string_expr(to_string_arguments[0], to_string_arguments[1], options=to_string_options)
        raise WolframEvaluationError("ToString expects an expression, an optional supported form specifier, and options.")

    if evaluated_head_name == "ToBoxes":
        if len(evaluated_arguments) == 1:
            return to_boxes_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return to_boxes_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("ToBoxes expects an expression and an optional form.")

    if evaluated_head_name == "StripBoxes":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("StripBoxes expects exactly one box expression.")
        return strip_boxes_expr(evaluated_arguments[0])

    if evaluated_head_name == "SyntaxQ":
        if len(evaluated_arguments) == 1:
            return syntax_q_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return syntax_q_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("SyntaxQ expects input and an optional form.")

    if evaluated_head_name == "SyntaxLength":
        if len(evaluated_arguments) == 1:
            return syntax_length_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return syntax_length_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("SyntaxLength expects input and an optional form.")

    if evaluated_head_name == "ToExpression":
        if len(evaluated_arguments) == 1:
            return to_expression_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return to_expression_expr(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return to_expression_expr(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "ToExpression expects input, an optional supported form specifier, and an optional wrapper head."
        )

    if evaluated_head.name == "SameQ":
        return same_q(*evaluated_arguments)

    if evaluated_head.name == "UnsameQ":
        return unsame_q(*evaluated_arguments)

    if evaluated_head.name == "Characters":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Characters expects exactly one argument.")
        return characters(evaluated_arguments[0])

    if evaluated_head.name == "StringLength":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("StringLength expects exactly one argument.")
        return string_length(evaluated_arguments[0])

    if evaluated_head.name == "StringTake":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("StringTake expects exactly two arguments.")
        return string_take(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "StringDrop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("StringDrop expects exactly two arguments.")
        return string_drop(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "StringJoin":
        return string_join(*evaluated_arguments)

    if evaluated_head.name == "StringInsert":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("StringInsert expects a source string, an insertion string, and positions.")
        return string_insert(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "StringReverse":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("StringReverse expects exactly one argument.")
        return string_reverse(evaluated_arguments[0])

    if evaluated_head.name == "ToUpperCase":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("ToUpperCase expects exactly one argument.")
        return to_upper_case(evaluated_arguments[0])

    if evaluated_head.name == "ToLowerCase":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("ToLowerCase expects exactly one argument.")
        return to_lower_case(evaluated_arguments[0])

    if evaluated_head.name == "Capitalize":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Capitalize expects exactly one argument.")
        return capitalize_string(evaluated_arguments[0])

    if evaluated_head.name == "StringRepeat":
        if len(evaluated_arguments) == 2:
            return string_repeat(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_repeat(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "StringRepeat expects a string, a count, and an optional target length."
        )

    if evaluated_head.name == "StringPadLeft":
        if len(evaluated_arguments) == 2:
            return string_pad_left(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_pad_left(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "StringPadLeft expects a string, a target length, and an optional padding."
        )

    if evaluated_head.name == "StringPadRight":
        if len(evaluated_arguments) == 2:
            return string_pad_right(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_pad_right(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "StringPadRight expects a string, a target length, and an optional padding."
        )

    if evaluated_head.name == "StringSplit":
        if len(evaluated_arguments) == 1:
            return string_split(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return string_split(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError(
            "StringSplit currently expects a string and an optional separator."
        )

    if evaluated_head.name == "StringRiffle":
        if len(evaluated_arguments) == 1:
            return string_riffle(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return string_riffle(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError(
            "StringRiffle expects a list and an optional separator or {l, sep, r} triple."
        )

    if evaluated_head.name == "StringTrim":
        if len(evaluated_arguments) == 1:
            return string_trim(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return string_trim(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError(
            "StringTrim expects a string and an optional literal-string trim pattern."
        )

    if evaluated_head.name == "StringCount":
        if len(evaluated_arguments) == 2:
            return string_count(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError(
            "StringCount expects a string and a literal-string pattern."
        )

    if evaluated_head.name == "StringPosition":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_position(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_position(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("StringPosition expects a string, a pattern, and an optional match limit.")

    if evaluated_head.name == "StringContainsQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_contains_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringContainsQ expects a string and a pattern.")

    if evaluated_head.name == "StringMatchQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_match_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringMatchQ expects a string and a pattern.")

    if evaluated_head.name == "StringFreeQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_free_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringFreeQ expects a string and a pattern.")

    if evaluated_head.name == "StringStartsQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_starts_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringStartsQ expects a string and a pattern.")

    if evaluated_head.name == "StringEndsQ":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return string_ends_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringEndsQ expects a string and a pattern.")

    if evaluated_head.name == "StringCases":
        if len(evaluated_arguments) == 2:
            return string_cases(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_cases(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("StringCases expects a string, a pattern or rule, and an optional match limit.")

    if evaluated_head.name == "StringReplace":
        if len(evaluated_arguments) == 2:
            return string_replace(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return string_replace(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("StringReplace expects a string, rules, and an optional replacement limit.")

    if evaluated_head.name == "ToCharacterCode":
        if len(evaluated_arguments) == 1:
            return to_character_code(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return to_character_code(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("ToCharacterCode expects a string and an optional encoding.")

    if evaluated_head.name == "FromCharacterCode":
        if len(evaluated_arguments) == 1:
            return from_character_code(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return from_character_code(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("FromCharacterCode expects character codes and an optional encoding.")

    if evaluated_head.name == "StringToByteArray":
        if len(evaluated_arguments) == 1:
            return string_to_byte_array(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return string_to_byte_array(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("StringToByteArray expects a string and an optional encoding.")

    if evaluated_head.name == "ByteArrayToString":
        if len(evaluated_arguments) == 1:
            return byte_array_to_string(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return byte_array_to_string(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("ByteArrayToString expects a byte array and an optional encoding.")

    if evaluated_head.name == "ExportString":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ExportString currently expects an expression and an explicit format specification.")
        return export_string(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ImportString":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ImportString currently expects a string and an explicit format specification.")
        return import_string_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ExportByteArray":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ExportByteArray currently expects an expression and an explicit format specification.")
        return export_byte_array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ImportByteArray":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ImportByteArray currently expects a byte array and an explicit format specification.")
        return import_byte_array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "BaseEncode":
        if len(evaluated_arguments) == 1:
            return base_encode(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return base_encode(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("BaseEncode expects a byte array and an optional base encoding.")

    if evaluated_head.name == "BaseDecode":
        if len(evaluated_arguments) == 1:
            return base_decode(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return base_decode(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("BaseDecode expects a string and an optional base encoding.")

    if evaluated_head.name == "Association":
        return association(*evaluated_arguments)

    if evaluated_head.name == "AssociationQ":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("AssociationQ expects exactly one argument.")
        return association_q(evaluated_arguments[0])

    if evaluated_head.name == "Length":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Length expects exactly one argument.")
        return integer(length(evaluated_arguments[0]))

    if evaluated_head.name == "Depth":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Depth expects exactly one argument.")
        return integer(depth(evaluated_arguments[0]))

    if evaluated_head.name == "Dimensions":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Dimensions expects exactly one argument.")
        return dimensions_expr(evaluated_arguments[0])

    if evaluated_head.name == "ArrayDepth":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("ArrayDepth expects exactly one argument.")
        return array_depth(evaluated_arguments[0])

    if evaluated_head.name == "ArrayQ":
        if len(evaluated_arguments) == 1:
            return array_q(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return array_q(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return array_q(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("ArrayQ expects an expression, optional depth, and optional element test.")

    if evaluated_head.name == "Head":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Head expects exactly one argument.")
        return head_of(evaluated_arguments[0])

    if evaluated_head.name == "First":
        if len(evaluated_arguments) == 1:
            return first(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return first(evaluated_arguments[0], default=evaluated_arguments[1])
        raise WolframEvaluationError("First expects an expression and an optional default.")

    if evaluated_head.name == "Last":
        if len(evaluated_arguments) == 1:
            return last(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return last(evaluated_arguments[0], default=evaluated_arguments[1])
        raise WolframEvaluationError("Last expects an expression and an optional default.")

    if evaluated_head.name == "Rest":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Rest expects exactly one argument.")
        return rest(evaluated_arguments[0])

    if evaluated_head.name == "Most":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Most expects exactly one argument.")
        return most(evaluated_arguments[0])

    if evaluated_head.name == "Part":
        if len(evaluated_arguments) < 2:
            raise WolframEvaluationError("Part expects an expression and at least one part specification.")
        subject = evaluated_arguments[0]
        specs = evaluated_arguments[1:]
        return part(subject, *specs)

    if evaluated_head.name == "Extract":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Extract expects exactly two arguments.")
        subject = evaluated_arguments[0]
        positions = evaluated_arguments[1]
        return extract(subject, positions)

    if evaluated_head.name == "ArrayRules":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("ArrayRules expects exactly one argument.")
        return array_rules(evaluated_arguments[0])

    if evaluated_head.name == "Level":
        if len(evaluated_arguments) not in {2, 3}:
            raise WolframEvaluationError("Level expects an expression, a level specification, and an optional heads flag.")
        subject = evaluated_arguments[0]
        spec = evaluated_arguments[1]
        if len(evaluated_arguments) == 3:
            heads = evaluated_arguments[2]
            if not isinstance(heads, Symbol) or heads.name not in {"True", "False"}:
                raise WolframEvaluationError("The optional third Level argument must be True or False.")
            if heads.name == "True":
                raise WolframEvaluationError("Level[..., ..., True] is not implemented yet.")
        return _evaluated_list_expr(*level(subject, spec))

    if evaluated_head.name == "Take":
        if len(evaluated_arguments) < 2:
            raise WolframEvaluationError("Take expects at least one specification.")
        return take(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Drop":
        if len(evaluated_arguments) < 2:
            raise WolframEvaluationError("Drop expects at least one specification.")
        return drop(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Select":
        if len(evaluated_arguments) == 2:
            return select(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return select(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "Select expects an expression, a criterion or property specification, and an optional limit."
        )

    if evaluated_head.name == "Discard":
        if len(evaluated_arguments) == 2:
            return discard(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return discard(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "Discard expects an expression, a criterion or property specification, and an optional limit."
        )

    if evaluated_head.name == "SelectFirst":
        if len(evaluated_arguments) == 2:
            return select_first(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return select_first(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "SelectFirst expects an expression, a criterion or property specification, and an optional default."
        )

    if evaluated_head.name == "TakeWhile":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("TakeWhile expects exactly two arguments.")
        return take_while(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Boole":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Boole expects exactly one argument.")
        argument = evaluated_arguments[0]
        truth = _truth_value(argument)
        if truth is None:
            return evaluated_expr
        return integer(1 if truth else 0)

    if evaluated_head.name == "Append":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Append expects exactly two arguments.")
        return append(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Prepend":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Prepend expects exactly two arguments.")
        return prepend(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Join":
        if len(evaluated_arguments) < 1:
            raise WolframEvaluationError("Join expects at least one argument.")
        return join(*evaluated_arguments)

    if evaluated_head.name == "Reverse":
        if len(evaluated_arguments) == 1:
            return reverse(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return reverse(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError(
            "Reverse expects an expression and an optional level specification."
        )

    if evaluated_head.name == "RotateLeft":
        if len(evaluated_arguments) == 1:
            return rotate_left(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return rotate_left(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("RotateLeft expects an expression and an optional integer offset.")

    if evaluated_head.name == "RotateRight":
        if len(evaluated_arguments) == 1:
            return rotate_right(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return rotate_right(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("RotateRight expects an expression and an optional integer offset.")

    if evaluated_head.name == "Flatten":
        if len(evaluated_arguments) == 1:
            return flatten(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return flatten(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Flatten currently supports an expression and an optional level specification.")

    if evaluated_head.name == "FlattenAt":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("FlattenAt expects exactly two arguments.")
        return flatten_at(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Delete":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Delete expects exactly two arguments.")
        return delete(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Insert":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("Insert expects exactly three arguments.")
        return insert(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "ReplacePart":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ReplacePart expects exactly two arguments.")
        return replace_part(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Scan":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return scan(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return scan(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Scan expects a function, an expression, and an optional level specification.")

    if evaluated_head.name == "Apply":
        if len(evaluated_arguments) == 2:
            return apply_head(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return apply_head(
                evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2]
            )
        raise WolframEvaluationError(
            "Apply expects a head, an expression, and an optional level specification."
        )

    if evaluated_head.name == "MapApply":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("MapApply currently supports exactly two arguments.")
        return map_apply(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Map":
        if len(evaluated_arguments) == 2:
            return map_expr(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return map_expr(
                evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2]
            )
        raise WolframEvaluationError(
            "Map expects a function, an expression, and an optional level specification."
        )

    if evaluated_head.name == "MapAll":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("MapAll currently supports exactly two arguments.")
        return map_all(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "MapIndexed":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return map_indexed(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return map_indexed(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "MapIndexed expects a function, an expression, and an optional level specification."
        )

    if evaluated_head.name == "MapAt":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("MapAt currently supports exactly three arguments.")
        return map_at(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "Clip":
        return clip_expr(evaluated_arguments)

    if evaluated_head.name == "Construct":
        if not evaluated_arguments:
            raise WolframEvaluationError("Construct expects at least one argument.")
        return construct(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "ComposeList":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ComposeList expects exactly two arguments.")
        return compose_list(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Nest":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("Nest expects exactly three arguments.")
        return nest(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "NestList":
        if len(evaluated_arguments) != 3:
            raise WolframEvaluationError("NestList expects exactly three arguments.")
        return nest_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])

    if evaluated_head.name == "NestWhile":
        if 3 <= len(evaluated_arguments) <= 5:
            return nest_while(*evaluated_arguments)
        raise WolframEvaluationError(
            "NestWhile expects f, expr, test, optional m, optional max."
        )

    if evaluated_head.name == "NestWhileList":
        if 3 <= len(evaluated_arguments) <= 5:
            return nest_while_list(*evaluated_arguments)
        raise WolframEvaluationError(
            "NestWhileList expects f, expr, test, optional m, optional max."
        )

    if evaluated_head.name == "FixedPoint":
        if len(evaluated_arguments) == 2:
            return fixed_point(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return fixed_point(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("FixedPoint expects a function, an expression, and an optional iteration limit.")

    if evaluated_head.name == "FixedPointList":
        if len(evaluated_arguments) == 2:
            return fixed_point_list(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return fixed_point_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "FixedPointList expects a function, an expression, and an optional iteration limit."
        )

    if evaluated_head.name == "Operate":
        if len(evaluated_arguments) == 2:
            return operate(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return operate(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Operate expects an operator, an expression, and an optional positive level.")

    if evaluated_head.name == "Comap":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Comap expects exactly two arguments.")
        return comap(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ComapApply":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ComapApply expects exactly two arguments.")
        return comap_apply(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Through":
        if len(evaluated_arguments) == 1:
            return through(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return through(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Through expects an expression and an optional restricting head.")

    if evaluated_head.name == "MapThread":
        if len(evaluated_arguments) == 2:
            return map_thread(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return map_thread(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("MapThread expects a function, a list of sequences, and an optional level.")

    if evaluated_head.name == "Thread":
        if len(evaluated_arguments) == 1:
            return thread(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return thread(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Thread expects an expression and an optional thread head.")

    if evaluated_head.name == "Distribute":
        if len(evaluated_arguments) == 1:
            return distribute(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return distribute(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return distribute(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError(
            "Distribute currently supports an expression, an optional distributed head, and an optional outer head."
        )

    if evaluated_head.name == "Outer":
        if len(evaluated_arguments) < 2:
            raise WolframEvaluationError("Outer expects a function and at least one sequence.")
        return outer(evaluated_arguments[0], *evaluated_arguments[1:])

    if evaluated_head.name == "Inner":
        if len(evaluated_arguments) != 4:
            raise WolframEvaluationError("Inner expects exactly four arguments.")
        return inner(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2], evaluated_arguments[3])

    if evaluated_head.name == "Dot":
        return dot(evaluated_arguments)

    if evaluated_head.name == "Cross":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Cross currently expects exactly two vector arguments.")
        return cross(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Tr":
        if len(evaluated_arguments) == 1:
            return tr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return tr(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return tr(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Tr expects an array, an optional combiner, and an optional rank-restriction integer.")

    if evaluated_head.name == "Transpose":
        if len(evaluated_arguments) == 1:
            return transpose(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return transpose(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Transpose expects an array and an optional permutation.")

    if evaluated_head.name == "Det":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Det expects exactly one matrix argument.")
        return det(evaluated_arguments[0])

    if evaluated_head.name == "Inverse":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Inverse expects exactly one matrix argument.")
        return inverse(evaluated_arguments[0])

    if evaluated_head.name == "MatrixPower":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("MatrixPower expects a matrix and an integer exponent.")
        return matrix_power(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Tuples":
        if len(evaluated_arguments) == 1:
            return tuples_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return tuples_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Tuples expects a list of sequences or a sequence with a repetition count.")

    if evaluated_head.name == "Array":
        if len(evaluated_arguments) == 2:
            return array(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return array(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Array expects two or three arguments.")

    if evaluated_head.name == "ArrayFlatten":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("ArrayFlatten expects exactly one argument.")
        return array_flatten(evaluated_arguments[0])

    if evaluated_head.name == "ArrayPad":
        if len(evaluated_arguments) == 2:
            return array_pad(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return array_pad(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("ArrayPad expects an array, padding widths, and an optional padding value.")

    if evaluated_head.name == "ArrayReshape":
        if len(evaluated_arguments) == 2:
            return array_reshape(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return array_reshape(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("ArrayReshape expects an expression, dimensions, and an optional padding value.")

    if evaluated_head.name == "ConstantArray":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ConstantArray currently supports exactly two arguments.")
        return constant_array(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Range":
        return range_expr(evaluated_arguments)

    if evaluated_head.name == "UnitVector":
        return unit_vector(evaluated_arguments)

    if evaluated_head.name == "IdentityMatrix":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("IdentityMatrix expects exactly one argument.")
        return identity_matrix(evaluated_arguments[0])

    if evaluated_head.name == "DiagonalMatrix":
        if len(evaluated_arguments) == 1:
            return diagonal_matrix(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return diagonal_matrix(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return diagonal_matrix(
                evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2]
            )
        raise WolframEvaluationError(
            "DiagonalMatrix expects a list, an optional offset, and an optional matrix size."
        )

    if evaluated_head.name == "LeviCivitaTensor":
        if len(evaluated_arguments) == 1:
            return levi_civita_tensor(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return levi_civita_tensor(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("LeviCivitaTensor expects a dimension and an optional head.")

    if evaluated_head.name == "Partition":
        if len(evaluated_arguments) == 2:
            return partition(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return partition(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return partition(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        if len(evaluated_arguments) == 5:
            return partition(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
            )
        raise WolframEvaluationError(
            "Partition expects an expression, a block size, an optional offset, "
            "an optional alignment k or {kL, kR}, and an optional padding value."
        )

    if evaluated_head.name == "BlockMap":
        if len(evaluated_arguments) == 3:
            return block_map(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return block_map(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError("BlockMap currently supports a function, an expression, a block size, and an optional offset.")

    if evaluated_head.name == "TakeList":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("TakeList expects exactly two arguments.")
        return take_list(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "TakeDrop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("TakeDrop expects exactly two arguments.")
        return take_drop(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Fold":
        if len(evaluated_arguments) == 2:
            return fold(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return fold(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Fold expects two or three arguments.")

    if evaluated_head.name == "FoldList":
        if len(evaluated_arguments) == 2:
            return fold_list(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return fold_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("FoldList expects two or three arguments.")

    if evaluated_head.name == "SequenceFold":
        if len(evaluated_arguments) == 3:
            return sequence_fold(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return sequence_fold(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "SequenceFold expects a function, initial values, inputs, and an optional argument count."
        )

    if evaluated_head.name == "SequenceFoldList":
        if len(evaluated_arguments) == 3:
            return sequence_fold_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return sequence_fold_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "SequenceFoldList expects a function, initial values, inputs, and an optional argument count."
        )

    if evaluated_head.name == "FoldWhile":
        if len(evaluated_arguments) == 4:
            return fold_while(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        if len(evaluated_arguments) == 5:
            return fold_while(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
            )
        if len(evaluated_arguments) == 6:
            return fold_while(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
                evaluated_arguments[5],
            )
        raise WolframEvaluationError(
            "FoldWhile currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
        )

    if evaluated_head.name == "FoldWhileList":
        if len(evaluated_arguments) == 4:
            return fold_while_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        if len(evaluated_arguments) == 5:
            return fold_while_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
            )
        if len(evaluated_arguments) == 6:
            return fold_while_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
                evaluated_arguments[4],
                evaluated_arguments[5],
            )
        raise WolframEvaluationError(
            "FoldWhileList currently supports a function, an initial value, inputs, a test, and optional history and trailing counts."
        )

    if evaluated_head.name == "FoldPair":
        if len(evaluated_arguments) == 3:
            return fold_pair(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return fold_pair(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "FoldPair currently supports a function, an initial value, inputs, and an optional projection."
        )

    if evaluated_head.name == "FoldPairList":
        if len(evaluated_arguments) == 3:
            return fold_pair_list(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return fold_pair_list(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError(
            "FoldPairList currently supports a function, an initial value, inputs, and an optional projection."
        )

    if evaluated_head.name == "LengthWhile":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("LengthWhile expects exactly two arguments.")
        return length_while(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "FirstCase":
        if len(evaluated_arguments) == 2:
            return first_case(evaluated_arguments[0], expr.arguments[1])
        if len(evaluated_arguments) == 3:
            return first_case(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return first_case(evaluated_arguments[0], expr.arguments[1], evaluated_arguments[2], evaluated_arguments[3])
        raise WolframEvaluationError(
            "FirstCase expects an expression, a pattern, and optional default and level specification."
        )

    if evaluated_head.name == "Position":
        # Strip an optional ``Heads -> True/False`` rule so the kernel idiom
        # ``Position[..., {1}, Heads -> False]`` works without surfacing the
        # rule as an unrecognized argument.
        position_args = list(evaluated_arguments)
        position_raw = list(expr.arguments)
        include_heads = True
        if position_args and _is_heads_option_rule(position_args[-1]):
            heads_rule = position_args.pop()
            position_raw.pop()
            assert isinstance(heads_rule, Call)
            include_heads = isinstance(heads_rule.arguments[1], Symbol) and heads_rule.arguments[1].name == "True"

        if len(position_args) == 2:
            return position(
                position_args[0], position_raw[1], include_heads=include_heads
            )
        if len(position_args) == 3:
            return position(
                position_args[0],
                position_raw[1],
                position_args[2],
                include_heads=include_heads,
            )
        if len(position_args) == 4:
            return position(
                position_args[0],
                position_raw[1],
                position_args[2],
                position_args[3],
                include_heads=include_heads,
            )
        raise WolframEvaluationError(
            "Position expects an expression, a pattern, and optional level and result limits."
        )

    if evaluated_head.name == "MemberQ":
        # Strip an optional trailing ``Heads -> True/False`` rule so
        # ``MemberQ[..., level, Heads -> False]`` works.
        member_args = list(evaluated_arguments)
        member_raw = list(expr.arguments)
        member_include_heads = False
        if member_args and _is_heads_option_rule(member_args[-1]):
            heads_rule = member_args.pop()
            member_raw.pop()
            assert isinstance(heads_rule, Call)
            member_include_heads = isinstance(heads_rule.arguments[1], Symbol) and heads_rule.arguments[1].name == "True"
        if len(member_args) == 2:
            return member_q(member_args[0], member_raw[1], include_heads=member_include_heads)
        if len(member_args) == 3:
            return member_q(member_args[0], member_raw[1], member_args[2], include_heads=member_include_heads)
        raise WolframEvaluationError("MemberQ expects an expression, a pattern, and an optional level specification.")

    if evaluated_head.name == "Order":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Order expects exactly two arguments.")
        return order_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "OrderedQ":
        if len(evaluated_arguments) == 1:
            return ordered_q(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return ordered_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("OrderedQ expects an expression and an optional ordering function.")

    if evaluated_head.name == "Ordering":
        ordering_args, same_test = _split_same_test_option_arguments(evaluated_arguments, "Ordering")
        if len(ordering_args) == 1:
            return ordering(ordering_args[0], same_test=same_test)
        if len(ordering_args) == 2:
            return ordering(ordering_args[0], ordering_args[1], same_test=same_test)
        if len(ordering_args) == 3:
            return ordering(ordering_args[0], ordering_args[1], ordering_args[2], same_test=same_test)
        raise WolframEvaluationError(
            "Ordering expects an expression, optional count, optional ordering function, and optional SameTest rule."
        )

    if evaluated_head.name == "Sort":
        sort_args, same_test = _split_same_test_option_arguments(evaluated_arguments, "Sort")
        if len(sort_args) == 1:
            return sort_expr(sort_args[0], same_test=same_test)
        if len(sort_args) == 2:
            return sort_expr(sort_args[0], sort_args[1], same_test=same_test)
        if len(sort_args) == 3:
            return sort_expr(sort_args[0], sort_args[1], sort_args[2], same_test=same_test)
        raise WolframEvaluationError(
            "Sort expects an expression, optional ordering function, optional count, and optional SameTest rule."
        )

    if evaluated_head.name == "AlphabeticSort":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("AlphabeticSort expects exactly one argument.")
        return alphabetic_sort(evaluated_arguments[0])

    if evaluated_head.name == "NumericalSort":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("NumericalSort expects exactly one argument.")
        return numerical_sort(evaluated_arguments[0])

    if evaluated_head.name == "RandomSample":
        if len(evaluated_arguments) == 1:
            return random_sample(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return random_sample(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("RandomSample expects an expression and an optional count.")

    if evaluated_head.name == "ReverseSort":
        sort_args, same_test = _split_same_test_option_arguments(evaluated_arguments, "ReverseSort")
        if len(sort_args) == 1:
            return sort_expr(sort_args[0], reverse=True, same_test=same_test)
        if len(sort_args) == 2:
            return sort_expr(sort_args[0], sort_args[1], reverse=True, same_test=same_test)
        if len(sort_args) == 3:
            return sort_expr(sort_args[0], sort_args[1], sort_args[2], reverse=True, same_test=same_test)
        raise WolframEvaluationError(
            "ReverseSort expects an expression, optional ordering function, optional count, and optional SameTest rule."
        )

    if evaluated_head.name == "SortBy":
        sort_args, same_test = _split_same_test_option_arguments(evaluated_arguments, "SortBy")
        if len(sort_args) == 1 and same_test is None:
            return evaluated_expr
        if len(sort_args) == 2:
            return sort_by(sort_args[0], sort_args[1], same_test=same_test)
        if len(sort_args) == 3:
            return sort_by(sort_args[0], sort_args[1], sort_args[2], same_test=same_test)
        raise WolframEvaluationError(
            "SortBy expects an expression, functions, optional ordering function, and optional SameTest rule."
        )

    if evaluated_head.name == "ReverseSortBy":
        sort_args, same_test = _split_same_test_option_arguments(evaluated_arguments, "ReverseSortBy")
        if len(sort_args) == 1 and same_test is None:
            return evaluated_expr
        if len(sort_args) == 2:
            return sort_by(sort_args[0], sort_args[1], reverse=True, same_test=same_test)
        if len(sort_args) == 3:
            return sort_by(sort_args[0], sort_args[1], sort_args[2], reverse=True, same_test=same_test)
        raise WolframEvaluationError(
            "ReverseSortBy expects an expression, functions, optional ordering function, and optional SameTest rule."
        )

    if evaluated_head.name == "OrderingBy":
        ordering_args, same_test = _split_same_test_option_arguments(evaluated_arguments, "OrderingBy")
        if len(ordering_args) == 1 and same_test is None:
            return evaluated_expr
        if len(ordering_args) == 2:
            return ordering_by(ordering_args[0], ordering_args[1], same_test=same_test)
        if len(ordering_args) == 3:
            return ordering_by(ordering_args[0], ordering_args[1], ordering_args[2], same_test=same_test)
        if len(ordering_args) == 4:
            return ordering_by(
                ordering_args[0],
                ordering_args[1],
                ordering_args[2],
                ordering_args[3],
                same_test=same_test,
            )
        raise WolframEvaluationError(
            "OrderingBy expects an expression, functions, optional count, optional ordering function, and optional SameTest rule."
        )

    if evaluated_head.name == "MinimalBy":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return minimal_by(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return minimal_by(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return minimal_by(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError("MinimalBy expects data, a function specification, optional count, and optional ordering function.")

    if evaluated_head.name == "MaximalBy":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return maximal_by(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return maximal_by(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        if len(evaluated_arguments) == 4:
            return maximal_by(
                evaluated_arguments[0],
                evaluated_arguments[1],
                evaluated_arguments[2],
                evaluated_arguments[3],
            )
        raise WolframEvaluationError("MaximalBy expects data, a function specification, optional count, and optional ordering function.")

    if evaluated_head.name == "LexicographicOrder":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return lexicographic_order(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return lexicographic_order(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("LexicographicOrder expects two expressions and an optional ordering function.")

    if evaluated_head.name == "LexicographicSort":
        if len(evaluated_arguments) == 1:
            return lexicographic_sort(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return lexicographic_sort(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("LexicographicSort expects an expression and an optional ordering function.")

    if evaluated_head.name == "DeleteDuplicates":
        if len(evaluated_arguments) == 1:
            return delete_duplicates(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return delete_duplicates(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("DeleteDuplicates expects an expression and an optional binary test.")

    if evaluated_head.name == "DeleteDuplicatesBy":
        if len(evaluated_arguments) == 2:
            return delete_duplicates_by(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return delete_duplicates_by(
                evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2]
            )
        raise WolframEvaluationError(
            "DeleteDuplicatesBy expects an expression, a key function, and an optional binary test."
        )

    if evaluated_head.name == "DeleteAdjacentDuplicates":
        if len(evaluated_arguments) == 1:
            return delete_adjacent_duplicates(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return delete_adjacent_duplicates(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("DeleteAdjacentDuplicates expects an expression and an optional binary test.")

    if evaluated_head.name == "Split":
        if len(evaluated_arguments) == 1:
            return split(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return split(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Split expects an expression and an optional binary test.")

    if evaluated_head.name == "SplitBy":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("SplitBy expects exactly two arguments.")
        return split_by(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "DuplicateFreeQ":
        if len(evaluated_arguments) == 1:
            return duplicate_free_q(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return duplicate_free_q(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("DuplicateFreeQ expects an expression and an optional binary test.")

    if evaluated_head.name == "Keys":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Keys expects exactly one argument.")
        return keys_expr(evaluated_arguments[0])

    if evaluated_head.name == "Values":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Values expects exactly one argument.")
        return values_expr(evaluated_arguments[0])

    if evaluated_head.name == "Normal":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Normal expects exactly one argument.")
        return normal(evaluated_arguments[0])

    if evaluated_head.name == "Lookup":
        if len(evaluated_arguments) == 2:
            return lookup(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return lookup(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Lookup expects an association, a key specification, and an optional default.")

    if evaluated_head.name == "KeyExistsQ":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyExistsQ expects exactly two arguments.")
        return key_exists_q(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyMemberQ":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyMemberQ expects exactly two arguments.")
        return key_member_q(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyTake":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyTake expects exactly two arguments.")
        return key_take(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyDrop":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyDrop expects exactly two arguments.")
        return key_drop(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeySelect":
        if len(evaluated_arguments) == 1:
            return evaluated_expr
        if len(evaluated_arguments) == 2:
            return key_select(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("KeySelect expects an association and a criterion.")

    if evaluated_head.name == "KeyMap":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyMap expects exactly two arguments.")
        return key_map(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "KeyValueMap":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("KeyValueMap expects exactly two arguments.")
        return key_value_map(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "AssociationThread":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("AssociationThread expects exactly two arguments.")
        return association_thread(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "AssociationMap":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("AssociationMap expects exactly two arguments.")
        return association_map(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Merge":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Merge expects exactly two arguments.")
        return merge_associations(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "GroupBy":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("GroupBy currently expects two arguments.")
        return group_by(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "GatherBy":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("GatherBy currently expects two arguments.")
        return gather_by(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Gather":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Gather expects exactly one argument.")
        return gather(evaluated_arguments[0])

    if evaluated_head.name == "KeyComplement":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("KeyComplement expects a list of associations.")
        return key_complement(evaluated_arguments[0])

    if evaluated_head.name == "KeyUnion":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("KeyUnion expects a list of associations.")
        return key_union(evaluated_arguments[0])

    if evaluated_head.name == "KeyIntersection":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("KeyIntersection expects a list of associations.")
        return key_intersection(evaluated_arguments[0])

    if evaluated_head.name == "KeySort":
        if len(evaluated_arguments) == 1:
            return key_sort(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return key_sort(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("KeySort expects an association and an optional ordering function.")

    if evaluated_head.name == "Total":
        if len(evaluated_arguments) == 1:
            return total(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return total(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Total expects a list/association and an optional levelspec.")

    if evaluated_head.name == "Mean":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Mean currently expects exactly one argument.")
        return mean_expr(evaluated_arguments[0])

    if evaluated_head.name == "Median":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Median currently expects exactly one argument.")
        return median_expr(evaluated_arguments[0])

    if evaluated_head.name == "Variance":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Variance currently expects exactly one argument.")
        return variance_expr(evaluated_arguments[0])

    if evaluated_head.name == "StandardDeviation":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("StandardDeviation currently expects exactly one argument.")
        return standard_deviation_expr(evaluated_arguments[0])

    if evaluated_head.name == "Norm":
        if len(evaluated_arguments) == 1:
            return norm_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return norm_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Norm expects a vector and an optional p value.")

    if evaluated_head.name == "Tally":
        if len(evaluated_arguments) == 1:
            return tally(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return tally(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Tally expects a list and an optional binary test.")

    if evaluated_head.name == "Counts":
        if len(evaluated_arguments) == 1:
            return counts(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return counts(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Counts expects a list or association and an optional binary test.")

    if evaluated_head.name == "MinMax":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("MinMax expects exactly one argument.")
        return min_max_expr(evaluated_arguments[0])

    if evaluated_head.name == "RankedMin":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("RankedMin expects a list and an integer rank.")
        return ranked_min_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "RankedMax":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("RankedMax expects a list and an integer rank.")
        return ranked_max_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Mode":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Mode expects exactly one argument.")
        return mode_expr(evaluated_arguments[0])

    if evaluated_head.name == "Quantile":
        if len(evaluated_arguments) == 2:
            return quantile_expr(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return quantile_expr(
                evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2]
            )
        raise WolframEvaluationError(
            "Quantile expects a list, a quantile (or list of quantiles), and an optional ``{{a, b}, {c, d}}`` parameter list."
        )

    if evaluated_head.name == "Quartiles":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Quartiles expects exactly one argument.")
        return quartiles_expr(evaluated_arguments[0])

    if evaluated_head.name == "BinCounts":
        if len(evaluated_arguments) == 1:
            return bin_counts_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return bin_counts_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("BinCounts expects a list and an optional bin spec.")

    if evaluated_head.name == "BinLists":
        if len(evaluated_arguments) == 1:
            return bin_lists_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return bin_lists_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("BinLists expects a list and an optional bin spec.")

    if evaluated_head.name == "Permute":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("Permute expects a list and a permutation specification.")
        return permute_expr(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "PermutationCycles":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("PermutationCycles expects exactly one positional permutation.")
        return permutation_cycles_expr(evaluated_arguments[0])

    if evaluated_head.name == "PermutationList":
        if len(evaluated_arguments) == 1:
            return permutation_list_expr(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return permutation_list_expr(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError(
            "PermutationList expects ``Cycles[{{…}}]`` and an optional non-negative integer length."
        )

    if evaluated_head.name == "PermutationOrder":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("PermutationOrder expects exactly one ``Cycles`` argument.")
        return permutation_order_expr(evaluated_arguments[0])

    if evaluated_head.name == "SequenceCases":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("SequenceCases expects a list and a List pattern.")
        return sequence_cases_expr(evaluated_arguments[0], expr.arguments[1])

    if evaluated_head.name == "SequencePosition":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("SequencePosition expects a list and a List pattern.")
        return sequence_position_expr(evaluated_arguments[0], expr.arguments[1])

    if evaluated_head.name == "SequenceCount":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("SequenceCount expects a list and a List pattern.")
        return sequence_count_expr(evaluated_arguments[0], expr.arguments[1])

    if evaluated_head.name == "Catenate":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("Catenate expects exactly one argument.")
        return catenate(evaluated_arguments[0])

    if evaluated_head.name == "Differences":
        if len(evaluated_arguments) == 1:
            return differences(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return differences(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Differences expects a list and an optional non-negative integer order.")

    if evaluated_head.name == "Accumulate":
        if len(evaluated_arguments) == 1:
            return accumulate(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return accumulate(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Accumulate expects a list and an optional binary combiner.")

    if evaluated_head.name == "Riffle":
        if len(evaluated_arguments) == 2:
            return riffle(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return riffle(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("Riffle expects a list, a separator, and an optional ``{a, b, s}`` span.")

    if evaluated_head.name == "Count":
        # Strip an optional trailing ``Heads -> True/False`` rule so
        # ``Count[..., level, Heads -> True]`` works.
        count_args = list(evaluated_arguments)
        count_raw = list(expr.arguments)
        count_include_heads = False
        if count_args and _is_heads_option_rule(count_args[-1]):
            heads_rule = count_args.pop()
            count_raw.pop()
            assert isinstance(heads_rule, Call)
            count_include_heads = isinstance(heads_rule.arguments[1], Symbol) and heads_rule.arguments[1].name == "True"
        if len(count_args) == 2:
            return count_items(count_args[0], count_raw[1], include_heads=count_include_heads)
        if len(count_args) == 3:
            return count_items(count_args[0], count_raw[1], count_args[2], include_heads=count_include_heads)
        raise WolframEvaluationError("Count expects an expression, a pattern, and an optional levelspec.")

    if evaluated_head.name == "AllTrue":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("AllTrue expects a list and a test function.")
        return all_true(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "AnyTrue":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("AnyTrue expects a list and a test function.")
        return any_true(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "NoneTrue":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("NoneTrue expects a list and a test function.")
        return none_true(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ContainsAll":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ContainsAll expects exactly two arguments.")
        return contains_all(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ContainsAny":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ContainsAny expects exactly two arguments.")
        return contains_any(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ContainsNone":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ContainsNone expects exactly two arguments.")
        return contains_none(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "ContainsExactly":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ContainsExactly expects exactly two arguments.")
        return contains_exactly(evaluated_arguments[0], evaluated_arguments[1])

    if evaluated_head.name == "Subsets":
        if len(evaluated_arguments) == 1:
            return subsets(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return subsets(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Subsets expects a list and an optional length spec.")

    if evaluated_head.name == "Subsequences":
        if len(evaluated_arguments) == 1:
            return subsequences(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return subsequences(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Subsequences expects a list and an optional length spec.")

    if evaluated_head.name == "Permutations":
        if len(evaluated_arguments) == 1:
            return permutations(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return permutations(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("Permutations expects a list and an optional length spec.")

    if evaluated_head.name == "RandomPermutation":
        if len(evaluated_arguments) != 1:
            raise WolframEvaluationError("RandomPermutation expects an integer length.")
        return random_permutation(evaluated_arguments[0])

    if evaluated_head.name == "Union":
        return union(evaluated_arguments)

    if evaluated_head.name == "Intersection":
        return intersection(evaluated_arguments)

    if evaluated_head.name == "Complement":
        return complement(evaluated_arguments)

    if evaluated_head.name == "PadLeft":
        if len(evaluated_arguments) == 2:
            return pad_left(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return pad_left(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("PadLeft expects a list, a target length, and an optional fill value.")

    if evaluated_head.name == "PadRight":
        if len(evaluated_arguments) == 2:
            return pad_right(evaluated_arguments[0], evaluated_arguments[1])
        if len(evaluated_arguments) == 3:
            return pad_right(evaluated_arguments[0], evaluated_arguments[1], evaluated_arguments[2])
        raise WolframEvaluationError("PadRight expects a list, a target length, and an optional fill value.")

    if evaluated_head.name == "FromDigits":
        if len(evaluated_arguments) == 1:
            return from_digits(evaluated_arguments[0])
        if len(evaluated_arguments) == 2:
            return from_digits(evaluated_arguments[0], evaluated_arguments[1])
        raise WolframEvaluationError("FromDigits expects digits and an optional base.")

    if evaluated_head.name == "ChineseRemainder":
        if len(evaluated_arguments) != 2:
            raise WolframEvaluationError("ChineseRemainder expects two list arguments.")
        return chinese_remainder(evaluated_arguments[0], evaluated_arguments[1])

    return evaluated_expr
