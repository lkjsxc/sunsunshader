mod bindings;
mod fingerprint;
mod taint;

use horizon_shader_api::check::{CheckedStage, MAX_EXPRESSIONS, MAX_TEXTURE_READS, Report};
use horizon_shader_api::kept::{MAX_BEFORE_WORLD, MAX_COMPUTE_POST, MAX_RESOURCES, Shape};
use horizon_shader_api::manifest::{MAX_POST_PASSES, MAX_POST_TARGETS, POST_TARGET_BUDGET};
use horizon_shader_api::{Composed, Pack, StageKind, check, compose};
use naga::{Function, Handle, ShaderStage};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::env;
use std::fs;
use std::path::Path;
use std::process::ExitCode;
use taint::{Analysis, Call, Site};

const HORIZON_REVISION: &str = "5ef7734fdd854add5efd6817178be3c988d8d050";
const NAGA_VERSION: &str = "30.0.1";

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Registration {
    file: String,
    boundary: String,
    fingerprint: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scope {
    kind: String,
    file: String,
    root: String,
    proven: BTreeMap<String, Registration>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Policy {
    schema: u32,
    stages: Vec<Scope>,
}

fn main() -> ExitCode {
    let args: Vec<_> = env::args_os().skip(1).collect();
    let result = match args.as_slice() {
        [pack, policy] => run(Path::new(pack), Path::new(policy)),
        _ => Err("usage: post-ir PACK POLICY".into()),
    };
    match result {
        Ok(receipt) => {
            println!("{}", serde_json::to_string_pretty(&receipt).unwrap());
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("{error}");
            ExitCode::FAILURE
        }
    }
}

fn run(path: &Path, policy: &Path) -> Result<Value, String> {
    let policy = fs::read(policy).map_err(|error| format!("{}: {error}", policy.display()))?;
    let policy: Policy = serde_json::from_slice(&policy).map_err(|error| error.to_string())?;
    if policy.schema != 1 {
        return Err("unsupported post continuity policy schema".into());
    }
    let pack = Pack::read(path)?;
    let mut unique = HashSet::new();
    for post in &pack.manifest.post {
        if !unique.insert(&post.file) {
            return Err(format!(
                "{}: post files must be unique for IR span mapping",
                post.file
            ));
        }
    }
    let report = check(&pack).map_err(|errors| {
        let errors: Vec<_> = errors.iter().map(ToString::to_string).collect();
        format!(
            "Horizon validation refused the pack:\n{}",
            errors.join("\n")
        )
    })?;

    let mut scopes = Vec::new();
    for scope in &policy.stages {
        let stage = report
            .stages
            .iter()
            .find(|stage| stage.kind.name() == scope.kind && stage.file == scope.file)
            .ok_or_else(|| format!("{}: missing scoped {} stage", scope.file, scope.kind))?;
        scopes.push(scan_stage(&pack, stage, scope)?);
    }
    Ok(json!({
        "horizon_revision": HORIZON_REVISION,
        "naga_version": NAGA_VERSION,
        "stages": scopes,
        "binding_checks": bindings::resolved(&report),
        "budget": budget(&report)
    }))
}

fn composition(pack: &Pack, stage: &CheckedStage) -> Result<Composed, String> {
    if stage.scene.is_some() {
        return Err(format!(
            "{}: post continuity requires the stock stage without a ray scene",
            stage.file
        ));
    }
    let composed = compose(pack, stage.kind, &stage.file);
    if !composed.text.starts_with(&stage.source) {
        return Err(format!(
            "{}: composition differs from the checked module",
            stage.file
        ));
    }
    Ok(composed)
}

fn scan_stage(pack: &Pack, stage: &CheckedStage, scope: &Scope) -> Result<Value, String> {
    let composed = composition(pack, stage)?;
    let module = &stage.module;
    let expected = match stage.kind {
        StageKind::Post => "horizon_fs_post",
        StageKind::Tonemap => "horizon_fs_tonemap",
        _ => {
            return Err(format!(
                "{}: continuity scope requires a post or tonemap draw",
                stage.file
            ));
        }
    };
    let entry = module
        .entry_points
        .iter()
        .position(|entry| entry.stage == ShaderStage::Fragment && entry.name == expected)
        .ok_or_else(|| format!("{}: missing Horizon entry point {expected}", stage.file))?;
    let mut analysis = Analysis::new(module, &stage.info);
    let entry = analysis.entry(entry)?;

    let mut all_contexts = HashSet::new();
    let mut pending = entry.calls;
    let mut roots = Vec::new();
    while let Some(call) = pending.pop() {
        if !all_contexts.insert(call.clone()) {
            continue;
        }
        if module.functions[call.function()].name.as_deref() == Some(&scope.root) {
            roots.push(call);
        } else {
            pending.extend(analysis.summary(&call).calls.iter().cloned());
        }
    }
    if roots.is_empty() {
        return Err(format!(
            "{}: {} is unreachable from {expected}",
            stage.file, scope.root
        ));
    }

    let mut visited = HashSet::<Call>::new();
    let mut scanned = BTreeMap::<Handle<Function>, BTreeMap<Site, bool>>::new();
    while let Some(call) = roots.pop() {
        if !visited.insert(call.clone()) {
            continue;
        }
        let summary = analysis.summary(&call);
        roots.extend(summary.calls.iter().cloned());
        let function = call.function();
        let file = function_file(stage, &composed, function)?;
        if !file.starts_with('<') {
            let sites = scanned.entry(function).or_default();
            for (site, &tainted) in &summary.decisions {
                *sites.entry(site.clone()).or_default() |= tainted;
            }
        }
    }

    let mut functions = Vec::new();
    let mut clean_decisions = 0;
    let mut proven = Vec::new();
    let mut registered = BTreeSet::new();
    let mut refusals = Vec::new();
    for (&function, decisions) in &scanned {
        let ir = &module.functions[function];
        let name = ir
            .name
            .as_deref()
            .ok_or("unnamed WGSL function in continuity scope")?;
        let file = function_file(stage, &composed, function)?;
        functions.push(json!({"name": name, "file": file}));
        clean_decisions += decisions.values().filter(|&&tainted| !tainted).count();
        let dirty: Vec<_> = decisions
            .iter()
            .filter(|&(_, &tainted)| tainted)
            .map(|(site, _)| Decision::new(&composed, file, site))
            .collect();
        match scope.proven.get(name) {
            Some(expected) => {
                registered.insert(name);
                let actual = fingerprint::fingerprint(module, ir);
                if file != expected.file || actual != expected.fingerprint {
                    refusals.push(format!(
                        "{file}: {name} fingerprint mismatch (got {actual}){}",
                        dirty
                            .first()
                            .map(|site| format!("; {}", site.refusal()))
                            .unwrap_or_default()
                    ));
                }
                proven.push(
                    json!({"function": name, "file": file, "boundary": expected.boundary,
                    "fingerprint": actual, "tainted_decisions": dirty}),
                );
            }
            None => {
                if let Some(site) = dirty.first() {
                    refusals.push(format!("{} in {name}", site.refusal()));
                }
            }
        }
    }
    for name in scope.proven.keys() {
        if !registered.contains(name.as_str()) {
            refusals.push(format!(
                "{}: missing post continuity boundary {name}",
                stage.file
            ));
        }
    }
    if !refusals.is_empty() {
        return Err(refusals.join("\n"));
    }
    Ok(json!({
        "kind": stage.kind.name(),
        "file": stage.file,
        "label": stage.label,
        "roots": [scope.root],
        "functions_scanned": functions,
        "untainted_decisions": clean_decisions,
        "proven_boundaries": proven,
        "inherited_exceptions": []
    }))
}

fn function_file<'a>(
    stage: &CheckedStage,
    composed: &'a Composed,
    function: Handle<Function>,
) -> Result<&'a str, String> {
    let span = stage
        .module
        .functions
        .get_span(function)
        .to_range()
        .ok_or_else(|| {
            format!(
                "{}: missing span for {:?}",
                stage.file, stage.module.functions[function].name
            )
        })?;
    Ok(composed.locate(span.start).0)
}

#[derive(serde::Serialize)]
struct Decision<'a> {
    operation: &'static str,
    file: &'a str,
    line: usize,
    column: usize,
}

impl<'a> Decision<'a> {
    fn new(composed: &'a Composed, fallback: &'a str, site: &Site) -> Self {
        let (file, line, column) = site
            .offset
            .map_or((fallback, 0, 0), |offset| composed.locate(offset));
        Self {
            operation: site.operation,
            file,
            line,
            column,
        }
    }

    fn refusal(&self) -> String {
        let Self {
            operation,
            file,
            line,
            column,
        } = self;
        format!("{file}:{line}:{column}: unproved post choice '{operation}' on image data")
    }
}

fn budget(report: &Report) -> Value {
    let manifest = &report.manifest;
    let targets = manifest.post_targets();
    let resources = &manifest.kept.resources;
    // manifest.rs accounts in exact sixteenths of a full rgba16float target.
    let sixteenths = |scale: f32| (16.0 * scale * scale) as u32;
    let target_cost: u32 = targets.iter().map(|&(_, scale)| sixteenths(scale)).sum();
    let kept_cost: u32 = resources
        .iter()
        .filter_map(|resource| match resource.shape {
            Shape::Scaled { scale, format } => Some(sixteenths(scale) * format.bytes() as u32 / 4),
            Shape::Buffer { .. } | Shape::Fixed { .. } => None,
        })
        .sum();
    let computes = manifest.post.iter().filter(|stage| stage.compute).count();
    json!({
        "draw_passes": manifest.post.len() - computes,
        "compute_entries": computes,
        "before_world_entries": manifest.kept.before_world.len(),
        "resources": resources.len(),
        "plain_outputs": targets.len(),
        "target_sixteenths": target_cost + kept_cost,
        "plain_target_sixteenths": target_cost,
        "kept_target_sixteenths": kept_cost,
        "limits": {
            "draw_passes": MAX_POST_PASSES,
            "compute_entries": MAX_COMPUTE_POST,
            "before_world_entries": MAX_BEFORE_WORLD,
            "resources": MAX_RESOURCES,
            "plain_outputs": MAX_POST_TARGETS,
            "target_sixteenths": 16 * POST_TARGET_BUDGET,
            "expressions": MAX_EXPRESSIONS,
            "texture_reads": MAX_TEXTURE_READS
        },
        "stages": report.stages.iter().map(|stage| json!({
            "kind": stage.kind.name(), "file": stage.file, "label": stage.label,
            "expressions": stage.expressions, "texture_reads": stage.texture_reads
        })).collect::<Vec<_>>()
    })
}
