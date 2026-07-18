use std::fmt;
use std::str::FromStr;

use num_bigint::BigInt;
use num_rational::BigRational;
use num_traits::{One, Zero};
use serde::ser::Serialize;
use serde_json::{Map, Number, Value};

use crate::wolfram_strings::wl_string;

/// Kernel-free representation of a Wolfram expression.
///
/// `Box` is used only at the recursive head/complex-number seams. Call arguments
/// stay contiguous in a `Vec`, which is the common traversal path in the evaluator.
#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub enum Expr {
    Symbol(String),
    Integer(BigInt),
    Real(String),
    Rational(BigRational),
    Complex {
        real: Box<Self>,
        imaginary: Box<Self>,
    },
    Root {
        coefficients: Vec<BigInt>,
        /// Zero-based root index internally, matching the Python implementation.
        index: usize,
        method: i64,
    },
    SpecialReal(String),
    String(String),
    ByteArray(Vec<u8>),
    SparseArray {
        dimensions: Vec<usize>,
        entries: Vec<(Vec<usize>, Self)>,
        fill_value: Box<Self>,
    },
    Call {
        head: Box<Self>,
        args: Vec<Self>,
    },
}

impl Expr {
    pub fn length(&self) -> usize {
        match self {
            Self::SparseArray { dimensions, .. } => dimensions.first().copied().unwrap_or(0),
            Self::ByteArray(values) => values.len(),
            _ => self.args().len(),
        }
    }

    pub fn depth(&self) -> usize {
        match self {
            Self::SparseArray { dimensions, .. } => dimensions.len() + 1,
            Self::Call { args, .. } if args.is_empty() => 2,
            Self::Call { args, .. } => 1 + args.iter().map(Self::depth).max().unwrap_or(1),
            Self::Root { .. } => 1,
            _ => 1,
        }
    }

    pub fn head(&self) -> Self {
        match self {
            Self::Symbol(_) => symbol("Symbol"),
            Self::Integer(_) => symbol("Integer"),
            Self::Real(_) | Self::SpecialReal(_) => symbol("Real"),
            Self::Rational(_) => symbol("Rational"),
            Self::Complex { .. } => symbol("Complex"),
            Self::Root { .. } => symbol("Root"),
            Self::String(_) => symbol("String"),
            Self::ByteArray(_) => symbol("ByteArray"),
            Self::SparseArray { .. } => symbol("SparseArray"),
            Self::Call { head, .. } => head.as_ref().clone(),
        }
    }

    pub fn args(&self) -> &[Self] {
        match self {
            Self::Call { args, .. } => args,
            _ => &[],
        }
    }

    pub fn is_atom(&self) -> bool {
        !matches!(self, Self::Call { .. } | Self::Root { .. })
    }

    pub fn symbol_name(&self) -> Option<&str> {
        match self {
            Self::Symbol(name) => Some(name),
            _ => None,
        }
    }

    pub fn has_head(&self, expected: &str) -> bool {
        match self {
            Self::Call { head, .. } => head
                .symbol_name()
                .is_some_and(|name| system_dispatch_name(name) == expected),
            Self::Root { .. } => expected == "Root",
            _ => false,
        }
    }

    pub fn to_full_form(&self) -> String {
        match self {
            Self::Symbol(name) => crate::named_characters::encode_printable_ascii(name),
            Self::Integer(value) => value.to_string(),
            Self::Real(text) => text.clone(),
            Self::Rational(value) => format!("Rational[{}, {}]", value.numer(), value.denom()),
            Self::Complex { real, imaginary } => format!(
                "Complex[{}, {}]",
                real.to_full_form(),
                imaginary.to_full_form()
            ),
            Self::Root {
                coefficients,
                index,
                method,
            } => {
                let body = polynomial_from_coefficients(coefficients, call("Slot", [integer(1)]));
                format!(
                    "Root[Function[{}], {}, {}]",
                    body.to_full_form(),
                    index + 1,
                    method
                )
            }
            Self::SpecialReal(name) => format!("{name}[]"),
            Self::String(value) => wl_string(value),
            Self::ByteArray(values) => {
                use base64::Engine;
                let encoded = base64::engine::general_purpose::STANDARD.encode(values);
                format!("ByteArray[{}]", wl_string(&encoded))
            }
            Self::SparseArray {
                dimensions,
                entries,
                fill_value,
            } => {
                let rules = entries.iter().map(|(indices, value)| {
                    call(
                        "Rule",
                        [
                            list(indices.iter().map(|value| integer(*value))),
                            value.clone(),
                        ],
                    )
                });
                let mut arguments = vec![
                    list(rules),
                    list(dimensions.iter().map(|value| integer(*value))),
                ];
                if fill_value.as_ref() != &integer(0) {
                    arguments.push(fill_value.as_ref().clone());
                }
                call("SparseArray", arguments).to_full_form()
            }
            Self::Call { head, args } => format!(
                "{}[{}]",
                head.to_full_form(),
                args.iter()
                    .map(Self::to_full_form)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }

    pub fn to_input_form(&self) -> String {
        crate::expression::format::format_input(self, 0)
    }

    fn to_json_value(&self) -> Value {
        let mut object = Map::new();
        match self {
            Self::Symbol(name) => {
                object.insert("type".into(), Value::String("symbol".into()));
                object.insert("name".into(), Value::String(name.clone()));
            }
            Self::Integer(value) => {
                object.insert("type".into(), Value::String("integer".into()));
                object.insert("value".into(), bigint_json(value));
            }
            Self::Real(text) => {
                object.insert("type".into(), Value::String("real".into()));
                object.insert("text".into(), Value::String(text.clone()));
            }
            Self::Rational(value) => {
                object.insert("type".into(), Value::String("rational".into()));
                object.insert("numerator".into(), bigint_json(value.numer()));
                object.insert("denominator".into(), bigint_json(value.denom()));
            }
            Self::Complex { real, imaginary } => {
                object.insert("type".into(), Value::String("complex".into()));
                object.insert("real".into(), real.to_json_value());
                object.insert("imaginary".into(), imaginary.to_json_value());
            }
            Self::Root {
                coefficients,
                index,
                method,
            } => {
                object.insert("type".into(), Value::String("root".into()));
                object.insert(
                    "coefficients".into(),
                    Value::Array(coefficients.iter().map(bigint_json).collect()),
                );
                object.insert("index".into(), Value::from(index + 1));
                object.insert("method".into(), Value::from(*method));
            }
            Self::SpecialReal(name) => {
                object.insert("type".into(), Value::String("real".into()));
                object.insert("special".into(), Value::String(name.clone()));
            }
            Self::String(value) => {
                object.insert("type".into(), Value::String("string".into()));
                object.insert("value".into(), Value::String(value.clone()));
            }
            Self::ByteArray(values) => {
                use base64::Engine;
                object.insert("type".into(), Value::String("byte_array".into()));
                object.insert(
                    "values".into(),
                    Value::Array(values.iter().copied().map(Value::from).collect()),
                );
                object.insert(
                    "base64".into(),
                    Value::String(base64::engine::general_purpose::STANDARD.encode(values)),
                );
                object.insert("length".into(), Value::from(values.len()));
            }
            Self::SparseArray {
                dimensions,
                entries,
                fill_value,
            } => {
                object.insert("type".into(), Value::String("sparse_array".into()));
                object.insert(
                    "dimensions".into(),
                    Value::Array(dimensions.iter().copied().map(Value::from).collect()),
                );
                object.insert("fill_value".into(), fill_value.to_json_value());
                object.insert(
                    "entries".into(),
                    Value::Array(
                        entries
                            .iter()
                            .map(|(indices, value)| {
                                let mut entry = Map::new();
                                entry.insert(
                                    "indices".into(),
                                    Value::Array(
                                        indices.iter().copied().map(Value::from).collect(),
                                    ),
                                );
                                entry.insert("value".into(), value.to_json_value());
                                Value::Object(entry)
                            })
                            .collect(),
                    ),
                );
                object.insert("explicit_length".into(), Value::from(entries.len()));
            }
            Self::Call { head, args } => {
                object.insert("type".into(), Value::String("call".into()));
                object.insert("head".into(), head.to_json_value());
                object.insert(
                    "args".into(),
                    Value::Array(args.iter().map(Self::to_json_value).collect()),
                );
            }
        }
        Value::Object(object)
    }
}

impl Serialize for Expr {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        self.to_json_value().serialize(serializer)
    }
}

impl fmt::Display for Expr {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.to_input_form())
    }
}

pub fn symbol(name: impl Into<String>) -> Expr {
    Expr::Symbol(name.into())
}

pub fn integer(value: impl Into<BigInt>) -> Expr {
    Expr::Integer(value.into())
}

pub fn real(text: impl Into<String>) -> Expr {
    Expr::Real(text.into())
}

pub fn rational(numerator: impl Into<BigInt>, denominator: impl Into<BigInt>) -> Expr {
    let numerator = numerator.into();
    let denominator = denominator.into();
    if denominator.is_zero() {
        return if numerator.is_zero() {
            symbol("Indeterminate")
        } else {
            symbol("ComplexInfinity")
        };
    }
    let value = BigRational::new(numerator, denominator);
    if value.denom().is_one() {
        integer(value.numer().clone())
    } else {
        Expr::Rational(value)
    }
}

pub fn complex(real: Expr, imaginary: Expr) -> Expr {
    let imaginary_is_zero = matches!(&imaginary, Expr::Integer(value) if value.is_zero())
        || matches!(&imaginary, Expr::Rational(value) if value.is_zero());
    if imaginary_is_zero {
        real
    } else {
        Expr::Complex {
            real: Box::new(real),
            imaginary: Box::new(imaginary),
        }
    }
}

pub fn string(value: impl Into<String>) -> Expr {
    Expr::String(value.into())
}

pub fn list(items: impl IntoIterator<Item = Expr>) -> Expr {
    call("List", items)
}

pub fn call(head: impl IntoExprHead, args: impl IntoIterator<Item = Expr>) -> Expr {
    let head = head.into_expr_head();
    let mut normalized = Vec::new();
    let flat = head.symbol_name().is_some_and(|name| {
        matches!(
            system_dispatch_name(name),
            "Alternatives" | "CompoundExpression"
        )
    });
    for argument in args {
        if flat && argument.has_head(head.symbol_name().unwrap_or_default()) {
            if let Expr::Call { args, .. } = argument {
                normalized.extend(args);
                continue;
            }
        }
        normalized.push(argument);
    }
    Expr::Call {
        head: Box::new(head),
        args: normalized,
    }
}

pub trait IntoExprHead {
    fn into_expr_head(self) -> Expr;
}

impl IntoExprHead for Expr {
    fn into_expr_head(self) -> Expr {
        self
    }
}

impl IntoExprHead for &str {
    fn into_expr_head(self) -> Expr {
        symbol(self)
    }
}

impl IntoExprHead for String {
    fn into_expr_head(self) -> Expr {
        symbol(self)
    }
}

pub(crate) fn system_dispatch_name(name: &str) -> &str {
    name.strip_prefix("System`").unwrap_or(name)
}

fn bigint_json(value: &BigInt) -> Value {
    Number::from_str(&value.to_string())
        .map_or_else(|_| Value::String(value.to_string()), Value::Number)
}

fn polynomial_from_coefficients(coefficients: &[BigInt], variable: Expr) -> Expr {
    let mut terms = Vec::new();
    for (exponent, coefficient) in coefficients.iter().enumerate() {
        if coefficient.is_zero() {
            continue;
        }
        let coefficient_expr = integer(coefficient.clone());
        if exponent == 0 {
            terms.push(coefficient_expr);
            continue;
        }
        let power = if exponent == 1 {
            variable.clone()
        } else {
            call("Power", [variable.clone(), integer(exponent)])
        };
        if coefficient.is_one() {
            terms.push(power);
        } else if coefficient == &-BigInt::one() {
            terms.push(call("Times", [integer(-1), power]));
        } else {
            terms.push(call("Times", [coefficient_expr, power]));
        }
    }
    match terms.len() {
        0 => integer(0),
        1 => terms.pop().expect("one term"),
        _ => call("Plus", terms),
    }
}
