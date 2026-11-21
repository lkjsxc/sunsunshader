//! Canonical print of a function's validated IR. Expression and local indices
//! are function-relative. References outside it are rendered by name and type.
use naga::{ArraySize, Block, Expression, Function, Handle, Module, Statement, Type, TypeInner};
use sha2::{Digest, Sha256};
use std::fmt::Write;

pub fn fingerprint(module: &Module, function: &Function) -> String {
    let mut printer = Printer {
        module,
        text: String::new(),
    };
    writeln!(printer.text, "{:?}", function.name).unwrap();
    for argument in &function.arguments {
        printer.ty(argument.ty);
        writeln!(printer.text, "{:?}", argument.binding).unwrap();
    }
    if let Some(result) = &function.result {
        printer.ty(result.ty);
        writeln!(printer.text, "{:?}", result.binding).unwrap();
    }
    for (_, local) in function.local_variables.iter() {
        printer.ty(local.ty);
        writeln!(printer.text, "{:?}", local.init).unwrap();
    }
    for (_, expression) in function.expressions.iter() {
        printer.expression(expression);
    }
    printer.block(&function.body);
    format!("{:x}", Sha256::digest(printer.text))
}

struct Printer<'a> {
    module: &'a Module,
    text: String,
}

impl Printer<'_> {
    fn ty(&mut self, handle: Handle<Type>) {
        let ty = &self.module.types[handle];
        write!(self.text, "type({:?} ", ty.name).unwrap();
        match &ty.inner {
            TypeInner::Pointer { base, space } => {
                write!(self.text, "Pointer {space:?} ").unwrap();
                self.ty(*base);
            }
            TypeInner::Array { base, size, stride } => {
                write!(self.text, "Array {stride} ").unwrap();
                self.ty(*base);
                self.array_size(*size);
            }
            TypeInner::BindingArray { base, size } => {
                write!(self.text, "BindingArray ").unwrap();
                self.ty(*base);
                self.array_size(*size);
            }
            TypeInner::Struct { members, span } => {
                write!(self.text, "Struct {span} ").unwrap();
                for member in members {
                    write!(
                        self.text,
                        "{:?} {:?} {} ",
                        member.name, member.binding, member.offset
                    )
                    .unwrap();
                    self.ty(member.ty);
                }
            }
            leaf @ (TypeInner::Scalar(_)
            | TypeInner::Vector { .. }
            | TypeInner::Matrix { .. }
            | TypeInner::CooperativeMatrix { .. }
            | TypeInner::Atomic(_)
            | TypeInner::ValuePointer { .. }
            | TypeInner::Image { .. }
            | TypeInner::Sampler { .. }
            | TypeInner::AccelerationStructure { .. }
            | TypeInner::RayQuery { .. }) => {
                write!(self.text, "{leaf:?}").unwrap();
            }
        }
        write!(self.text, ")").unwrap();
    }

    fn array_size(&mut self, size: ArraySize) {
        match size {
            ArraySize::Constant(size) => write!(self.text, " constant {size}").unwrap(),
            ArraySize::Dynamic => write!(self.text, " dynamic").unwrap(),
            ArraySize::Pending(handle) => self.override_(handle),
        }
    }

    fn override_(&mut self, handle: Handle<naga::Override>) {
        let item = &self.module.overrides[handle];
        write!(self.text, "Override {:?} {:?} ", item.name, item.id).unwrap();
        self.ty(item.ty);
        self.initializer(item.init);
    }

    fn initializer(&mut self, init: Option<Handle<Expression>>) {
        // Global expression handles are module-relative. Print the operands
        // recursively instead of including their allocation indices.
        if let Some(handle) = init {
            self.global_expression(handle);
        } else {
            writeln!(self.text, "none").unwrap();
        }
    }

    fn global_expression(&mut self, handle: Handle<Expression>) {
        use Expression::*;
        let expression = &self.module.global_expressions[handle];
        match expression {
            Compose { ty, components } => {
                write!(self.text, "Compose ").unwrap();
                self.ty(*ty);
                for component in components {
                    self.global_expression(*component);
                }
                writeln!(self.text, "end compose").unwrap();
            }
            Access { base, index } => {
                writeln!(self.text, "Access").unwrap();
                self.global_expression(*base);
                self.global_expression(*index);
            }
            AccessIndex { base, index } => {
                writeln!(self.text, "AccessIndex {index}").unwrap();
                self.global_expression(*base);
            }
            Splat { size, value } => {
                writeln!(self.text, "Splat {size:?}").unwrap();
                self.global_expression(*value);
            }
            Swizzle {
                size,
                vector,
                pattern,
            } => {
                writeln!(self.text, "Swizzle {size:?} {pattern:?}").unwrap();
                self.global_expression(*vector);
            }
            Unary { op, expr } => {
                writeln!(self.text, "Unary {op:?}").unwrap();
                self.global_expression(*expr);
            }
            Binary { op, left, right } => {
                writeln!(self.text, "Binary {op:?}").unwrap();
                self.global_expression(*left);
                self.global_expression(*right);
            }
            Select {
                condition,
                accept,
                reject,
            } => {
                writeln!(self.text, "Select").unwrap();
                for operand in [condition, accept, reject] {
                    self.global_expression(*operand);
                }
            }
            Math {
                fun,
                arg,
                arg1,
                arg2,
                arg3,
            } => {
                writeln!(self.text, "Math {fun:?}").unwrap();
                for operand in [Some(*arg), *arg1, *arg2, *arg3] {
                    self.initializer(operand);
                }
            }
            Relational { fun, argument } => {
                writeln!(self.text, "Relational {fun:?}").unwrap();
                self.global_expression(*argument);
            }
            As {
                expr,
                kind,
                convert,
            } => {
                writeln!(self.text, "As {kind:?} {convert:?}").unwrap();
                self.global_expression(*expr);
            }
            // Horizon validates the module before we print it.
            Literal(_) | Constant(_) | Override(_) | ZeroValue(_) => self.expression(expression),
            FunctionArgument(_)
            | GlobalVariable(_)
            | LocalVariable(_)
            | Load { .. }
            | ImageSample { .. }
            | ImageLoad { .. }
            | ImageQuery { .. }
            | Derivative { .. }
            | CallResult(_)
            | AtomicResult { .. }
            | WorkGroupUniformLoadResult { .. }
            | ArrayLength(_)
            | RayQueryVertexPositions { .. }
            | RayQueryProceedResult
            | RayQueryGetIntersection { .. }
            | SubgroupBallotResult
            | SubgroupOperationResult { .. }
            | CooperativeLoad { .. }
            | CooperativeMultiplyAdd { .. } => {
                unreachable!("validated global expression: {expression:?}")
            }
        }
    }

    fn expression(&mut self, expression: &Expression) {
        use Expression::*;
        match expression {
            Constant(handle) => {
                let item = &self.module.constants[*handle];
                write!(self.text, "Constant {:?} ", item.name).unwrap();
                self.ty(item.ty);
                self.global_expression(item.init);
            }
            Override(handle) => self.override_(*handle),
            GlobalVariable(handle) => {
                let global = &self.module.global_variables[*handle];
                write!(
                    self.text,
                    "Global {:?} {:?} {:?} ",
                    global.name, global.space, global.binding
                )
                .unwrap();
                self.ty(global.ty);
                self.initializer(global.init);
            }
            Compose { ty, components } => {
                write!(self.text, "Compose {components:?} ").unwrap();
                self.ty(*ty);
                writeln!(self.text).unwrap();
            }
            ZeroValue(ty) | WorkGroupUniformLoadResult { ty } | SubgroupOperationResult { ty } => {
                let op = match expression {
                    ZeroValue(_) => "ZeroValue",
                    WorkGroupUniformLoadResult { .. } => "WorkGroupUniformLoadResult",
                    _ => "SubgroupOperationResult",
                };
                write!(self.text, "{op} ").unwrap();
                self.ty(*ty);
                writeln!(self.text).unwrap();
            }
            AtomicResult { ty, comparison } => {
                write!(self.text, "AtomicResult {comparison} ").unwrap();
                self.ty(*ty);
                writeln!(self.text).unwrap();
            }
            CallResult(handle) => {
                writeln!(
                    self.text,
                    "CallResult {:?}",
                    self.module.functions[*handle].name
                )
                .unwrap();
            }
            Literal(_)
            | Access { .. }
            | AccessIndex { .. }
            | Splat { .. }
            | Swizzle { .. }
            | FunctionArgument(_)
            | LocalVariable(_)
            | Load { .. }
            | ImageSample { .. }
            | ImageLoad { .. }
            | ImageQuery { .. }
            | Unary { .. }
            | Binary { .. }
            | Select { .. }
            | Derivative { .. }
            | Relational { .. }
            | Math { .. }
            | As { .. }
            | ArrayLength(_)
            | RayQueryVertexPositions { .. }
            | RayQueryProceedResult
            | RayQueryGetIntersection { .. }
            | SubgroupBallotResult
            | CooperativeLoad { .. }
            | CooperativeMultiplyAdd { .. } => {
                writeln!(self.text, "{expression:?}").unwrap();
            }
        }
    }

    fn block(&mut self, block: &Block) {
        use Statement::*;
        writeln!(self.text, "{{").unwrap();
        for statement in block.iter() {
            match statement {
                Block(inner) => self.block(inner),
                If {
                    condition,
                    accept,
                    reject,
                } => {
                    writeln!(self.text, "If {condition:?}").unwrap();
                    self.block(accept);
                    self.block(reject);
                }
                Switch { selector, cases } => {
                    writeln!(self.text, "Switch {selector:?}").unwrap();
                    for case in cases {
                        writeln!(self.text, "{:?} {}", case.value, case.fall_through).unwrap();
                        self.block(&case.body);
                    }
                }
                Loop {
                    body,
                    continuing,
                    break_if,
                } => {
                    writeln!(self.text, "Loop {break_if:?}").unwrap();
                    self.block(body);
                    self.block(continuing);
                }
                Call {
                    function,
                    arguments,
                    result,
                } => {
                    writeln!(
                        self.text,
                        "Call {:?} {arguments:?} {result:?}",
                        self.module.functions[*function].name
                    )
                    .unwrap();
                }
                Emit(_)
                | Break
                | Continue
                | Return { .. }
                | Kill
                | ControlBarrier(_)
                | MemoryBarrier(_)
                | Store { .. }
                | ImageStore { .. }
                | Atomic { .. }
                | ImageAtomic { .. }
                | WorkGroupUniformLoad { .. }
                | RayQuery { .. }
                | RayPipelineFunction(_)
                | SubgroupBallot { .. }
                | SubgroupGather { .. }
                | SubgroupCollectiveOperation { .. }
                | CooperativeStore { .. } => {
                    writeln!(self.text, "{statement:?}").unwrap();
                }
            }
        }
        writeln!(self.text, "}}").unwrap();
    }
}
