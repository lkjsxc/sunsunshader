use naga::valid::{FunctionInfo, ModuleInfo};
use naga::{
    AddressSpace, BinaryOperator, Block, Expression, Function, Handle, MathFunction, Module,
    SampleLevel, ScalarKind, Span, Statement, TypeInner,
};
use std::collections::{BTreeMap, HashMap};

type Expr = Handle<Expression>;
type Func = Handle<Function>;

#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
enum Taint {
    #[default]
    Clean,
    Fields(BTreeMap<u32, Taint>),
    Image,
}

impl Taint {
    fn field(&self, index: u32) -> Self {
        match self {
            Self::Fields(fields) => fields.get(&index).cloned().unwrap_or_default(),
            leaf => leaf.clone(),
        }
    }

    fn at(self, path: &[u32]) -> Self {
        if let Some((&index, rest)) = path.split_first()
            && self != Self::Clean
        {
            return Self::Fields(BTreeMap::from([(index, self.at(rest))]));
        }
        self
    }

    fn join(&mut self, other: Self) {
        match (&mut *self, other) {
            (Self::Image, _) | (_, Self::Clean) => {}
            (Self::Fields(left), Self::Fields(right)) => {
                for (index, value) in right {
                    left.entry(index).or_default().join(value);
                }
            }
            (_, value) => *self = value,
        }
    }

    fn collapsed(&self) -> Self {
        image(self != &Self::Clean)
    }
}

fn image(tainted: bool) -> Taint {
    if tainted { Taint::Image } else { Taint::Clean }
}

#[derive(Clone, Debug, Default, Eq, Hash, PartialEq)]
struct Argument {
    taint: Taint,
    binding: Option<(u32, u32)>,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
pub struct Call(Func, Vec<Argument>);

impl Call {
    pub fn function(&self) -> Func {
        self.0
    }
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Site {
    // Prefer the decision a shader author sees over its lowering to compares.
    pub priority: u8,
    pub offset: Option<usize>,
    pub operation: &'static str,
}

#[derive(Debug, Default)]
pub struct Summary {
    returned: Taint,
    pointer_writes: BTreeMap<u32, Taint>,
    pub calls: Vec<Call>,
    pub decisions: BTreeMap<Site, bool>,
}

pub struct Analysis<'a> {
    module: &'a Module,
    info: &'a ModuleInfo,
    summaries: HashMap<Call, Summary>,
    work: usize,
}

impl<'a> Analysis<'a> {
    pub fn new(module: &'a Module, info: &'a ModuleInfo) -> Self {
        Self {
            module,
            info,
            summaries: HashMap::new(),
            work: 0,
        }
    }

    pub fn entry(&mut self, index: usize) -> Result<Summary, String> {
        let entry = &self.module.entry_points[index].function;
        let arguments = vec![Argument::default(); entry.arguments.len()];
        self.evaluate(entry, self.info.get_entry_point(index), &arguments)
    }

    pub fn summary(&self, call: &Call) -> &Summary {
        &self.summaries[call]
    }

    fn evaluate(
        &mut self,
        function: &Function,
        info: &FunctionInfo,
        arguments: &[Argument],
    ) -> Result<Summary, String> {
        let mut scan = Scan {
            function,
            info,
            arguments,
            expressions: vec![Taint::Clean; function.expressions.len()],
            locals: vec![Taint::Clean; function.local_variables.len()],
            writes: BTreeMap::new(),
            summary: Summary::default(),
            module: self.module,
        };
        // Dependencies run both ways through local stores and pointer calls.
        // Each pass only adds taint. The final pass records the stabilized call
        // contexts and decisions, including the loop back edges.
        loop {
            self.work += 1 + function.expressions.len();
            if self.work > 2_000_000 {
                return Err("post IR analysis exceeded its work budget".into());
            }
            let prior = (
                scan.expressions.clone(),
                scan.locals.clone(),
                scan.writes.clone(),
            );
            scan.summary = Summary::default();
            for (handle, expression) in function.expressions.iter() {
                let value = scan.expression(expression, function.expressions.get_span(handle));
                scan.expressions[handle.index()].join(value);
            }
            for (handle, local) in function.local_variables.iter() {
                if let Some(init) = local.init {
                    let value = scan.value(init).clone();
                    scan.locals[handle.index()].join(value);
                }
            }
            scan.block(&function.body, self)?;
            if (&prior.0, &prior.1, &prior.2) == (&scan.expressions, &scan.locals, &scan.writes) {
                scan.summary.pointer_writes = scan.writes;
                return Ok(scan.summary);
            }
        }
    }

    fn call(&mut self, call: &Call) -> Result<&Summary, String> {
        if !self.summaries.contains_key(call) {
            let module = self.module;
            let info = self.info;
            // Validated WGSL has no recursion; functions can only call earlier
            // functions in this arena.
            let summary = self.evaluate(&module.functions[call.0], &info[call.0], &call.1)?;
            self.summaries.insert(call.clone(), summary);
        }
        Ok(&self.summaries[call])
    }
}

struct Scan<'a> {
    function: &'a Function,
    info: &'a FunctionInfo,
    module: &'a Module,
    arguments: &'a [Argument],
    expressions: Vec<Taint>,
    locals: Vec<Taint>,
    writes: BTreeMap<u32, Taint>,
    summary: Summary,
}

impl Scan<'_> {
    fn value(&self, expr: Expr) -> &Taint {
        &self.expressions[expr.index()]
    }

    fn tainted(&self, operands: impl IntoIterator<Item = Expr>) -> bool {
        operands
            .into_iter()
            .any(|operand| self.value(operand) != &Taint::Clean)
    }

    fn decision(&mut self, span: Span, priority: u8, operation: &'static str, tainted: bool) {
        let site = Site {
            priority,
            offset: span.to_range().map(|range| range.start),
            operation,
        };
        *self.summary.decisions.entry(site).or_default() |= tainted;
    }

    fn binding(&self, expr: Expr) -> Option<(u32, u32)> {
        match self.function.expressions[expr] {
            Expression::GlobalVariable(handle) => self.module.global_variables[handle]
                .binding
                .as_ref()
                .map(|binding| (binding.group, binding.binding)),
            Expression::FunctionArgument(index) => self.arguments[index as usize].binding,
            _ => None,
        }
    }

    fn expression(&mut self, expression: &Expression, span: Span) -> Taint {
        use Expression::*;
        match *expression {
            Literal(_) | Constant(_) | Override(_) | ZeroValue(_) => Taint::Clean,
            Compose { ty, ref components } => {
                if matches!(self.module.types[ty].inner, TypeInner::Struct { .. }) {
                    Taint::Fields(
                        components
                            .iter()
                            .enumerate()
                            .filter_map(|(index, &component)| {
                                let taint = self.value(component);
                                (taint != &Taint::Clean).then(|| (index as u32, taint.clone()))
                            })
                            .collect(),
                    )
                    .normalize()
                } else {
                    image(self.tainted(components.iter().copied()))
                }
            }
            FunctionArgument(index) => {
                let mut value = self.arguments[index as usize].taint.clone();
                value.join(self.writes.get(&index).cloned().unwrap_or_default());
                value
            }
            GlobalVariable(handle) => image(!matches!(
                self.module.global_variables[handle].space,
                AddressSpace::Uniform | AddressSpace::Handle
            )),
            LocalVariable(handle) => self.locals[handle.index()].clone(),
            Load { pointer } => self.value(pointer).clone(),
            AccessIndex { base, index } => self.value(base).field(index),
            Access { base, index } => {
                self.decision(span, 3, "dynamic access index", self.tainted([index]));
                image(self.tainted([base, index]))
            }
            Splat { value, .. }
            | Swizzle { vector: value, .. }
            | Derivative { expr: value, .. } => self.value(value).collapsed(),
            ImageLoad {
                image: source,
                coordinate,
                array_index,
                sample,
                level,
            } => {
                let indices = [Some(source), Some(coordinate), array_index, sample, level];
                self.decision(
                    span,
                    2,
                    "textureLoad",
                    self.tainted(indices.into_iter().flatten()),
                );
                Taint::Image
            }
            ImageSample {
                image: source,
                coordinate,
                sampler,
                gather,
                array_index,
                offset,
                level,
                depth_ref,
                clamp_to_edge: _,
            } => {
                let lod = match level {
                    SampleLevel::Auto | SampleLevel::Zero => [None, None],
                    SampleLevel::Exact(expr) | SampleLevel::Bias(expr) => [Some(expr), None],
                    SampleLevel::Gradient { x, y } => [Some(x), Some(y)],
                };
                let indices = [
                    Some(source),
                    Some(sampler),
                    array_index,
                    offset,
                    depth_ref,
                    lod[0],
                    lod[1],
                ];
                let linear_tap = gather.is_none() && self.binding(sampler) == Some((3, 4));
                let hard = self.tainted(indices.into_iter().flatten())
                    || (!linear_tap && self.tainted([coordinate]));
                // Coordinate-only linear taps are continuous, so count only
                // operations that can make a hard selection.
                if !linear_tap || indices[2..].iter().any(Option::is_some) {
                    self.decision(span, 2, "textureSample", hard);
                }
                Taint::Image
            }
            ImageQuery {
                image: source,
                query,
            } => {
                let level = match query {
                    naga::ImageQuery::Size { level } => level,
                    naga::ImageQuery::NumLevels
                    | naga::ImageQuery::NumLayers
                    | naga::ImageQuery::NumSamples => None,
                };
                let taint = self.tainted([Some(source), level].into_iter().flatten());
                self.decision(span, 2, "texture query index", taint);
                image(taint)
            }
            Unary { op, expr } => {
                let taint = self.tainted([expr]);
                match op {
                    naga::UnaryOperator::Negate => {}
                    naga::UnaryOperator::LogicalNot | naga::UnaryOperator::BitwiseNot => {
                        self.decision(span, 4, "logical or bitwise negation", taint);
                    }
                }
                image(taint)
            }
            Binary { op, left, right } => {
                use BinaryOperator::*;
                let taint = self.tainted([left, right]);
                match op {
                    Add | Subtract | Multiply | Divide => {}
                    Equal | NotEqual | Less | LessEqual | Greater | GreaterEqual => {
                        self.decision(span, 4, "comparison", taint);
                    }
                    Modulo | And | ExclusiveOr | InclusiveOr | LogicalAnd | LogicalOr
                    | ShiftLeft | ShiftRight => {
                        self.decision(span, 4, "logical, bitwise or modulo operation", taint);
                    }
                }
                image(taint)
            }
            Select {
                condition,
                accept,
                reject,
            } => {
                let taint = self.tainted([condition]);
                self.decision(span, 1, "select", taint);
                let mut value = self.value(accept).clone();
                value.join(self.value(reject).clone());
                value.join(image(taint));
                value
            }
            Relational { argument, .. } => {
                let taint = self.tainted([argument]);
                self.decision(span, 4, "relational", taint);
                image(taint)
            }
            Math {
                fun,
                arg,
                arg1,
                arg2,
                arg3,
            } => {
                let taint = self.tainted([Some(arg), arg1, arg2, arg3].into_iter().flatten());
                if let Some(operation) = hard_math(fun) {
                    self.decision(span, 3, operation, taint);
                }
                image(taint)
            }
            As {
                expr,
                kind,
                convert,
            } => {
                let taint = self.tainted([expr]);
                let source = self.info[expr]
                    .ty
                    .inner_with(&self.module.types)
                    .scalar_kind();
                if convert.is_none()
                    || matches!(
                        (source, kind),
                        (
                            Some(ScalarKind::Float | ScalarKind::AbstractFloat),
                            ScalarKind::Sint | ScalarKind::Uint
                        ) | (Some(ScalarKind::Bool), ScalarKind::Float)
                    )
                {
                    self.decision(span, 3, "image-dependent cast", taint);
                }
                image(taint)
            }
            ArrayLength(_) => {
                // Length depends on the binding, not its contents. A dynamic
                // tainted index selecting a binding is checked at Access.
                Taint::Clean
            }
            // These results are supplied by their statements.
            CallResult(_) | SubgroupBallotResult | SubgroupOperationResult { .. } => Taint::Clean,
            AtomicResult { .. }
            | WorkGroupUniformLoadResult { .. }
            | RayQueryVertexPositions { .. }
            | RayQueryProceedResult
            | RayQueryGetIntersection { .. }
            | CooperativeLoad { .. } => Taint::Image,
            CooperativeMultiplyAdd { a, b, c } => image(self.tainted([a, b, c])),
        }
    }

    fn store(&mut self, mut pointer: Expr, mut value: Taint) {
        let mut path = Vec::new();
        loop {
            match self.function.expressions[pointer] {
                Expression::AccessIndex { base, index } => {
                    if let TypeInner::Pointer { base: ty, .. } =
                        self.info[base].ty.inner_with(&self.module.types)
                        && matches!(self.module.types[*ty].inner, TypeInner::Struct { .. })
                    {
                        path.push(index);
                    } else {
                        path.clear();
                        value = value.collapsed();
                    }
                    pointer = base;
                }
                Expression::Access { base, .. } => {
                    path.clear();
                    value = value.collapsed();
                    pointer = base;
                }
                Expression::LocalVariable(local) => {
                    path.reverse();
                    self.locals[local.index()].join(value.at(&path));
                    return;
                }
                Expression::FunctionArgument(index) => {
                    path.reverse();
                    self.writes.entry(index).or_default().join(value.at(&path));
                    return;
                }
                Expression::GlobalVariable(_) => return, // Mutable globals already read as tainted.
                _ => unreachable!("validated store pointer"),
            }
        }
    }

    fn block(&mut self, block: &Block, analysis: &mut Analysis<'_>) -> Result<(), String> {
        use Statement::*;
        for (statement, &span) in block.span_iter() {
            match statement {
                Block(inner) => self.block(inner, analysis)?,
                If {
                    condition,
                    accept,
                    reject,
                } => {
                    self.decision(span, 0, "if", self.tainted([*condition]));
                    self.block(accept, analysis)?;
                    self.block(reject, analysis)?;
                }
                Switch { selector, cases } => {
                    self.decision(span, 0, "switch", self.tainted([*selector]));
                    for case in cases {
                        self.block(&case.body, analysis)?;
                    }
                }
                Loop {
                    body,
                    continuing,
                    break_if,
                } => {
                    if let Some(condition) = break_if {
                        self.decision(span, 0, "break if", self.tainted([*condition]));
                    }
                    self.block(body, analysis)?;
                    self.block(continuing, analysis)?;
                }
                Store { pointer, value } => self.store(*pointer, self.value(*value).clone()),
                Return { value } => {
                    if let Some(value) = value {
                        self.summary
                            .returned
                            .join(self.expressions[value.index()].clone());
                    }
                }
                Call {
                    function,
                    arguments,
                    result,
                } => {
                    let arguments_key = arguments
                        .iter()
                        .map(|&expr| Argument {
                            taint: self.value(expr).clone(),
                            binding: self.binding(expr),
                        })
                        .collect();
                    let call = self::Call(*function, arguments_key);
                    let callee = analysis.call(&call)?;
                    if let Some(result) = result {
                        self.expressions[result.index()].join(callee.returned.clone());
                    }
                    for (&index, writes) in &callee.pointer_writes {
                        self.store(arguments[index as usize], writes.clone());
                    }
                    self.summary.calls.push(call);
                }
                ImageStore {
                    image,
                    coordinate,
                    array_index,
                    ..
                }
                | ImageAtomic {
                    image,
                    coordinate,
                    array_index,
                    ..
                } => {
                    self.decision(
                        span,
                        2,
                        "image write index",
                        self.tainted(
                            [Some(*image), Some(*coordinate), *array_index]
                                .into_iter()
                                .flatten(),
                        ),
                    );
                }
                Atomic {
                    fun:
                        naga::AtomicFunction::Exchange {
                            compare: Some(compare),
                        },
                    ..
                } => {
                    self.decision(span, 3, "atomic compare", self.tainted([*compare]));
                }
                SubgroupBallot { result, predicate } => {
                    let taint = self.tainted(*predicate);
                    self.decision(span, 3, "subgroup ballot", taint);
                    self.expressions[result.index()].join(image(taint));
                }
                SubgroupGather {
                    mode,
                    argument,
                    result,
                } => {
                    use naga::GatherMode::*;
                    let index = match mode {
                        BroadcastFirst | QuadSwap(_) => None,
                        Broadcast(index) | Shuffle(index) | ShuffleDown(index)
                        | ShuffleUp(index) | ShuffleXor(index) | QuadBroadcast(index) => {
                            Some(*index)
                        }
                    };
                    self.decision(span, 3, "subgroup index", self.tainted(index));
                    let value = image(self.tainted(index.into_iter().chain([*argument])));
                    self.expressions[result.index()].join(value);
                }
                SubgroupCollectiveOperation {
                    argument, result, ..
                } => {
                    let value = self.value(*argument).collapsed();
                    self.expressions[result.index()].join(value);
                }
                Emit(_)
                | Break
                | Continue
                | Kill
                | ControlBarrier(_)
                | MemoryBarrier(_)
                | Atomic { .. }
                | WorkGroupUniformLoad { .. }
                | RayQuery { .. }
                | RayPipelineFunction(_)
                | CooperativeStore { .. } => {}
            }
        }
        Ok(())
    }
}

impl Taint {
    fn normalize(self) -> Self {
        if matches!(&self, Self::Fields(fields) if fields.is_empty()) {
            Self::Clean
        } else {
            self
        }
    }
}

fn hard_math(fun: MathFunction) -> Option<&'static str> {
    use MathFunction::*;
    match fun {
        Abs | Min | Max | Clamp | Saturate | Mix | SmoothStep | Sqrt | Length | Dot | Exp | Sin
        | Cos | Normalize | Pow => None,
        Step => Some("step"),
        Sign => Some("sign"),
        Floor => Some("floor"),
        Ceil => Some("ceil"),
        Round => Some("round"),
        Fract => Some("fract"),
        Trunc => Some("trunc"),
        Modf => Some("modf"),
        Frexp => Some("frexp"),
        Cosh | Sinh | Tan | Tanh | Acos | Asin | Atan | Atan2 | Asinh | Acosh | Atanh | Radians
        | Degrees | Ldexp | Exp2 | Log | Log2 | Dot4I8Packed | Dot4U8Packed | Outer | Cross
        | Distance | FaceForward | Reflect | Refract | Fma | InverseSqrt | Inverse | Transpose
        | Determinant | QuantizeToF16 | CountTrailingZeros | CountLeadingZeros | CountOneBits
        | ReverseBits | ExtractBits | InsertBits | FirstTrailingBit | FirstLeadingBit
        | Pack4x8snorm | Pack4x8unorm | Pack2x16snorm | Pack2x16unorm | Pack2x16float
        | Pack4xI8 | Pack4xU8 | Pack4xI8Clamp | Pack4xU8Clamp | Unpack4x8snorm | Unpack4x8unorm
        | Unpack2x16snorm | Unpack2x16unorm | Unpack2x16float | Unpack4xI8 | Unpack4xU8 => {
            Some("math outside the continuity allowlist")
        }
    }
}
