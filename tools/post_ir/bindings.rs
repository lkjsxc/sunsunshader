use horizon_shader_api::StageKind;
use horizon_shader_api::check::{CheckedStage, Report};
use serde_json::{Value, json};

pub fn resolved(report: &Report) -> Value {
    let group = |stage: &CheckedStage| {
        let bindings: Vec<_> = stage
            .module
            .global_variables
            .iter()
            .filter_map(|(_, global)| {
                global.binding.as_ref().map(|binding| {
                    json!({
                        "name": global.name, "group": binding.group, "binding": binding.binding,
                        "address_space": format!("{:?}", global.space)
                    })
                })
            })
            .collect();
        json!({"file": stage.file, "kind": stage.kind.name(), "bindings": bindings})
    };
    let checked_bindings: Vec<_> = report
        .stages
        .iter()
        .filter(|stage| stage.kind == StageKind::Post || stage.kind == StageKind::Tonemap)
        .map(group)
        .collect();
    json!({"resolved_stages": checked_bindings})
}
