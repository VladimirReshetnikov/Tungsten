//! Discovery of installed Wolfram products and their local data roots.

use serde::Serialize;
use serde_json::{Value, json};
use std::collections::HashSet;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct WolframInstallationSummary {
    pub product: String,
    pub product_family: String,
    pub version: Option<String>,
    pub install_dir: PathBuf,
    pub kernel_cli: Option<PathBuf>,
    pub wolframscript: Option<PathBuf>,
}

impl WolframInstallationSummary {
    pub fn to_value(&self) -> Value {
        json!({
            "product": self.product,
            "product_family": self.product_family,
            "version": self.version,
            "install_dir": path_string(&self.install_dir),
            "kernel_cli": self.kernel_cli.as_deref().map(path_string),
            "wolframscript": self.wolframscript.as_deref().map(path_string),
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct WolframInstallation {
    pub install_dir: Option<PathBuf>,
    pub kernel_cli: Option<PathBuf>,
    pub kernel_executable: Option<PathBuf>,
    pub frontend_executable: Option<PathBuf>,
    pub wolframscript: Option<PathBuf>,
    pub mathpass: Option<PathBuf>,
    pub docs_roots: Vec<PathBuf>,
    pub bundled_python_client: Option<PathBuf>,
    pub default_index_path: PathBuf,
    pub product: String,
    pub product_family: String,
    pub version: Option<String>,
    pub user_base: Option<PathBuf>,
    pub system_base: Option<PathBuf>,
    pub mathpass_candidates: Vec<PathBuf>,
    pub available_installations: Vec<WolframInstallationSummary>,
    pub selection_reason: Option<String>,
}

impl WolframInstallation {
    pub fn to_value(&self) -> Value {
        json!({
            "install_dir": self.install_dir.as_deref().map(path_string),
            "kernel_cli": self.kernel_cli.as_deref().map(path_string),
            "kernel_executable": self.kernel_executable.as_deref().map(path_string),
            "frontend_executable": self.frontend_executable.as_deref().map(path_string),
            "wolframscript": self.wolframscript.as_deref().map(path_string),
            "mathpass": self.mathpass.as_deref().map(path_string),
            "docs_roots": self.docs_roots.iter().map(|path| path_string(path)).collect::<Vec<_>>(),
            "bundled_python_client": self.bundled_python_client.as_deref().map(path_string),
            "default_index_path": path_string(&self.default_index_path),
            "product": self.product,
            "product_family": self.product_family,
            "version": self.version,
            "user_base": self.user_base.as_deref().map(path_string),
            "system_base": self.system_base.as_deref().map(path_string),
            "mathpass_candidates": self.mathpass_candidates.iter().map(|path| path_string(path)).collect::<Vec<_>>(),
            "available_installations": self.available_installations.iter().map(WolframInstallationSummary::to_value).collect::<Vec<_>>(),
            "selection_reason": self.selection_reason,
        })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct DiscoveryEnvironment {
    pub program_files: PathBuf,
    pub appdata: Option<PathBuf>,
    pub program_data: PathBuf,
    pub local_app_data: Option<PathBuf>,
    pub home: Option<PathBuf>,
    pub explicit_home: Option<PathBuf>,
    pub requested_product: Option<String>,
}

impl DiscoveryEnvironment {
    pub fn from_current() -> Self {
        Self {
            program_files: env::var_os("ProgramFiles")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(r"C:\Program Files")),
            appdata: env::var_os("APPDATA").map(PathBuf::from),
            program_data: env::var_os("ProgramData")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(r"C:\ProgramData")),
            local_app_data: env::var_os("LOCALAPPDATA").map(PathBuf::from),
            home: env::var_os("HOME")
                .or_else(|| env::var_os("USERPROFILE"))
                .map(PathBuf::from),
            explicit_home: env::var_os("TUNGSTEN_WOLFRAM_HOME").map(PathBuf::from),
            requested_product: env::var("TUNGSTEN_WOLFRAM_PRODUCT").ok(),
        }
    }

    fn research_root(&self) -> PathBuf {
        self.program_files.join("Wolfram Research")
    }
}

#[derive(Clone, Copy)]
struct ProductLayout {
    product: &'static str,
    family: &'static str,
    program_files_name: &'static str,
    user_base_name: &'static str,
    index_prefix: &'static str,
    default_priority: usize,
}

const WOLFRAM_LAYOUT: ProductLayout = ProductLayout {
    product: "Wolfram",
    family: "wolfram",
    program_files_name: "Wolfram",
    user_base_name: "Wolfram",
    index_prefix: "wolfram",
    default_priority: 0,
};
const ENGINE_LAYOUT: ProductLayout = ProductLayout {
    product: "Wolfram Engine",
    family: "engine",
    program_files_name: "Wolfram Engine",
    user_base_name: "WolframEngine",
    index_prefix: "wolfram-engine",
    default_priority: 1,
};
const PRODUCT_LAYOUTS: [ProductLayout; 2] = [WOLFRAM_LAYOUT, ENGINE_LAYOUT];

pub fn discover_installation() -> WolframInstallation {
    discover_installation_in(&DiscoveryEnvironment::from_current())
}

pub fn discover_installation_in(environment: &DiscoveryEnvironment) -> WolframInstallation {
    let available = discover_available_installations(environment);
    let requested_family = requested_product_family(environment.requested_product.as_deref());
    let mut selected = None;
    let mut selection_reason = None;
    if environment.explicit_home.is_some() && !available.is_empty() {
        selected = available.first().cloned();
        selection_reason = Some("TUNGSTEN_WOLFRAM_HOME".to_owned());
    } else if let Some(requested) = requested_family {
        selected = available
            .iter()
            .find(|installation| installation.product_family == requested)
            .cloned();
        if selected.is_some() {
            selection_reason = Some(format!("TUNGSTEN_WOLFRAM_PRODUCT={requested}"));
        }
    }
    if selected.is_none() && !available.is_empty() {
        selected = available.first().cloned();
        selection_reason = Some("default-product-preference".to_owned());
    }
    let install_dir = selected
        .as_ref()
        .map(|summary| summary.install_dir.clone())
        .or_else(|| discover_installation_root(environment, &available));
    let layout = install_dir.as_deref().map_or(WOLFRAM_LAYOUT, infer_layout);
    let product = selected
        .as_ref()
        .map_or(layout.product, |summary| &summary.product)
        .to_owned();
    let product_family = selected
        .as_ref()
        .map_or(layout.family, |summary| &summary.product_family)
        .to_owned();
    let version = selected
        .as_ref()
        .and_then(|summary| summary.version.clone())
        .or_else(|| {
            install_dir.as_deref().and_then(|path| {
                let name = path.file_name()?.to_string_lossy();
                (!parse_version(&name).is_empty()).then(|| name.into_owned())
            })
        });
    let executable = |name: &str| {
        install_dir
            .as_ref()
            .map(|directory| directory.join(name))
            .filter(|path| path.exists())
    };
    let bundled_python_client = install_dir
        .as_ref()
        .map(|directory| {
            directory
                .join("SystemFiles")
                .join("Components")
                .join("WolframClientForPython")
        })
        .filter(|path| path.exists());
    let user_base = environment
        .appdata
        .as_ref()
        .map(|path| path.join(layout.user_base_name));
    let system_base = Some(environment.program_data.join(layout.user_base_name));
    let docs_roots = discover_docs_roots_in(
        install_dir.as_deref(),
        Some(layout.user_base_name),
        environment,
    );
    let mathpass_candidates = discover_mathpass_candidates(&product_family, environment);
    let mathpass = mathpass_candidates
        .iter()
        .find(|path| path.exists())
        .cloned();
    let local_app_data = environment.local_app_data.clone().unwrap_or_else(|| {
        environment
            .home
            .clone()
            .unwrap_or_else(|| PathBuf::from("."))
            .join("AppData")
            .join("Local")
    });
    let index_version = version
        .clone()
        .or_else(|| {
            install_dir
                .as_deref()
                .and_then(Path::file_name)
                .map(|name| name.to_string_lossy().into_owned())
        })
        .unwrap_or_else(|| "unknown".to_owned());
    let kernel_cli = executable("wolfram.exe");
    let kernel_executable = executable("WolframKernel.exe");
    let frontend_executable = executable("WolframNB.exe");
    let wolframscript = executable("wolframscript.exe");
    let existing_install_dir = install_dir.clone().filter(|path| path.exists());
    WolframInstallation {
        install_dir: existing_install_dir,
        kernel_cli,
        kernel_executable,
        frontend_executable,
        wolframscript,
        mathpass,
        docs_roots,
        bundled_python_client,
        default_index_path: local_app_data
            .join("Tungsten")
            .join("docs")
            .join(format!("{}-{index_version}.sqlite3", layout.index_prefix)),
        product,
        product_family,
        version,
        user_base,
        system_base,
        mathpass_candidates,
        available_installations: available,
        selection_reason,
    }
}

pub fn discover_docs_roots(install_dir: Option<&Path>) -> Vec<PathBuf> {
    let environment = DiscoveryEnvironment::from_current();
    discover_docs_roots_in(install_dir, None, &environment)
}

pub fn discover_docs_roots_in(
    install_dir: Option<&Path>,
    user_base_name: Option<&str>,
    environment: &DiscoveryEnvironment,
) -> Vec<PathBuf> {
    let layout = install_dir.map_or(WOLFRAM_LAYOUT, infer_layout);
    let install_version = install_dir
        .and_then(Path::file_name)
        .map(|name| parse_version(&name.to_string_lossy()))
        .unwrap_or_default();
    let mut base_names = vec![user_base_name.unwrap_or(layout.user_base_name)];
    if layout.user_base_name != "Wolfram" {
        base_names.push("Wolfram");
    }
    let mut roots = Vec::new();
    if let Some(appdata) = &environment.appdata {
        for base_name in base_names {
            let repository = appdata.join(base_name).join("Paclets").join("Repository");
            let mut updates = read_directories(&repository)
                .into_iter()
                .filter(|path| {
                    path.file_name()
                        .is_some_and(|name| name.to_string_lossy().starts_with("SystemDocsUpdate"))
                })
                .collect::<Vec<_>>();
            updates.sort_by(|left, right| right.cmp(left));
            for update in updates {
                if !install_version.is_empty() {
                    let update_version = trailing_version(&update);
                    if update_version.get(..install_version.len()) != Some(&install_version) {
                        continue;
                    }
                }
                let candidate = update.join("Documentation").join("English");
                if candidate.exists() {
                    roots.push(candidate);
                }
            }
        }
    }
    if let Some(install_dir) = install_dir
        && let Some(version) = install_dir.file_name()
    {
        let common = environment
            .research_root()
            .parent()
            .unwrap_or_else(|| Path::new(""))
            .join("Common Files")
            .join("Wolfram Research")
            .join("Documentation.en-us")
            .join(version)
            .join("Documentation")
            .join("English")
            .join("System");
        if common.exists() {
            roots.push(common);
        }
    }
    let mut seen = HashSet::new();
    roots
        .into_iter()
        .filter_map(|root| root.canonicalize().ok())
        .filter(|root| seen.insert(root.clone()))
        .collect()
}

pub fn ensure_parent_directory(path: &Path) -> std::io::Result<()> {
    path.parent().map_or(Ok(()), fs::create_dir_all)
}

pub fn notebook_files(roots: &[PathBuf]) -> Vec<PathBuf> {
    let mut output = Vec::new();
    for root in roots {
        collect_notebooks(root, &mut output);
    }
    output
}

fn collect_notebooks(path: &Path, output: &mut Vec<PathBuf>) {
    if !path.exists() {
        return;
    }
    if path.is_file() {
        if path.extension().is_some_and(|extension| extension == "nb") {
            output.push(path.to_path_buf());
        }
        return;
    }
    for child in read_entries(path) {
        collect_notebooks(&child, output);
    }
}

fn discover_available_installations(
    environment: &DiscoveryEnvironment,
) -> Vec<WolframInstallationSummary> {
    let mut discovered = Vec::new();
    let mut seen = HashSet::new();
    for candidate in installation_candidates(environment) {
        let install_dir = normalize_install_dir(&candidate);
        if !install_dir.is_dir() {
            continue;
        }
        let Ok(resolved) = install_dir.canonicalize() else {
            continue;
        };
        if !seen.insert(resolved.clone()) {
            continue;
        }
        let summary = summarize_install_dir(resolved);
        if summary.kernel_cli.is_some() || summary.wolframscript.is_some() {
            discovered.push(summary);
        }
    }
    discovered.sort_by(|left, right| {
        let left_layout = layout_by_family(&left.product_family);
        let right_layout = layout_by_family(&right.product_family);
        left_layout
            .default_priority
            .cmp(&right_layout.default_priority)
            .then_with(|| {
                parse_version(right.version.as_deref().unwrap_or_default())
                    .cmp(&parse_version(left.version.as_deref().unwrap_or_default()))
            })
            .then_with(|| {
                path_string(&left.install_dir)
                    .to_lowercase()
                    .cmp(&path_string(&right.install_dir).to_lowercase())
            })
    });
    discovered
}

fn installation_candidates(environment: &DiscoveryEnvironment) -> Vec<PathBuf> {
    if let Some(explicit) = &environment.explicit_home {
        return vec![normalize_install_dir(explicit)];
    }
    let research = environment.research_root();
    let mut candidates = Vec::new();
    for layout in PRODUCT_LAYOUTS {
        for child in read_directories(&research.join(layout.program_files_name)) {
            if child
                .file_name()
                .is_some_and(|name| !parse_version(&name.to_string_lossy()).is_empty())
            {
                candidates.push(child);
            }
        }
    }
    candidates
}

fn discover_installation_root(
    environment: &DiscoveryEnvironment,
    available: &[WolframInstallationSummary],
) -> Option<PathBuf> {
    if available.is_empty() {
        return environment
            .explicit_home
            .as_deref()
            .map(normalize_install_dir);
    }
    if environment.explicit_home.is_some() {
        return available.first().map(|summary| summary.install_dir.clone());
    }
    if let Some(requested) = requested_product_family(environment.requested_product.as_deref())
        && let Some(summary) = available
            .iter()
            .find(|summary| summary.product_family == requested)
    {
        return Some(summary.install_dir.clone());
    }
    available.first().map(|summary| summary.install_dir.clone())
}

fn normalize_install_dir(candidate: &Path) -> PathBuf {
    if candidate.is_file() {
        let parent = candidate.parent().unwrap_or(candidate);
        if let Some(system_files) = parent.ancestors().find(|ancestor| {
            ancestor
                .file_name()
                .is_some_and(|name| name.to_string_lossy().eq_ignore_ascii_case("systemfiles"))
        }) {
            return system_files.parent().unwrap_or(system_files).to_path_buf();
        }
        return parent.to_path_buf();
    }
    if candidate.exists()
        && candidate
            .file_name()
            .is_some_and(|name| !parse_version(&name.to_string_lossy()).is_empty())
    {
        return candidate.to_path_buf();
    }
    if candidate.is_dir() {
        let mut versions = read_directories(candidate)
            .into_iter()
            .filter(|path| {
                path.file_name()
                    .is_some_and(|name| !parse_version(&name.to_string_lossy()).is_empty())
            })
            .collect::<Vec<_>>();
        versions.sort_by(|left, right| {
            parse_version(&right.file_name().unwrap_or_default().to_string_lossy()).cmp(
                &parse_version(&left.file_name().unwrap_or_default().to_string_lossy()),
            )
        });
        if let Some(version) = versions.into_iter().next() {
            return version;
        }
    }
    candidate.to_path_buf()
}

fn summarize_install_dir(install_dir: PathBuf) -> WolframInstallationSummary {
    let layout = infer_layout(&install_dir);
    let kernel_cli = install_dir.join("wolfram.exe");
    let wolframscript = install_dir.join("wolframscript.exe");
    WolframInstallationSummary {
        product: layout.product.to_owned(),
        product_family: layout.family.to_owned(),
        version: install_dir.file_name().and_then(|name| {
            let name = name.to_string_lossy();
            (!parse_version(&name).is_empty()).then(|| name.into_owned())
        }),
        install_dir,
        kernel_cli: kernel_cli.exists().then_some(kernel_cli),
        wolframscript: wolframscript.exists().then_some(wolframscript),
    }
}

fn discover_mathpass_candidates(
    product_family: &str,
    environment: &DiscoveryEnvironment,
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if product_family == "engine" {
        if let Some(appdata) = &environment.appdata {
            candidates.push(
                appdata
                    .join("WolframEngine")
                    .join("Licensing")
                    .join("mathpass"),
            );
        }
        candidates.push(
            environment
                .program_data
                .join("WolframEngine")
                .join("Licensing")
                .join("mathpass"),
        );
    } else {
        candidates.push(
            environment
                .program_data
                .join("Wolfram")
                .join("Licensing")
                .join("mathpass"),
        );
        if let Some(appdata) = &environment.appdata {
            candidates.push(appdata.join("Wolfram").join("Licensing").join("mathpass"));
        }
    }
    candidates
}

fn infer_layout(path: &Path) -> ProductLayout {
    let normalized = path_string(path).to_lowercase();
    if normalized.contains("wolfram engine") || normalized.contains("wolframengine") {
        ENGINE_LAYOUT
    } else {
        WOLFRAM_LAYOUT
    }
}

fn layout_by_family(family: &str) -> ProductLayout {
    if family == "wolfram" {
        WOLFRAM_LAYOUT
    } else {
        ENGINE_LAYOUT
    }
}

fn requested_product_family(value: Option<&str>) -> Option<&str> {
    match value?.trim().to_ascii_lowercase().as_str() {
        "" => None,
        "wolfram" | "desktop" | "paid" | "mathematica" => Some("wolfram"),
        "engine" | "wolframengine" | "wolfram-engine" | "wefd" => Some("engine"),
        _ => None,
    }
}

fn parse_version(value: &str) -> Vec<i64> {
    let mut parts = Vec::new();
    for fragment in value.split('.') {
        let fragment = fragment.trim();
        if fragment.is_empty() {
            continue;
        }
        let Ok(part) = fragment.parse() else {
            break;
        };
        parts.push(part);
    }
    parts
}

fn trailing_version(path: &Path) -> Vec<i64> {
    let name = path
        .file_name()
        .map_or_else(String::new, |name| name.to_string_lossy().into_owned());
    let Some((_, version)) = name.rsplit_once('-') else {
        return Vec::new();
    };
    if version
        .chars()
        .all(|character| character.is_ascii_digit() || character == '.')
    {
        parse_version(version)
    } else {
        Vec::new()
    }
}

fn read_directories(path: &Path) -> Vec<PathBuf> {
    read_entries(path)
        .into_iter()
        .filter(|path| path.is_dir())
        .collect()
}

fn read_entries(path: &Path) -> Vec<PathBuf> {
    fs::read_dir(path)
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .collect()
}

fn path_string(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn fixture() -> (PathBuf, DiscoveryEnvironment) {
        let unique = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = env::temp_dir().join(format!("tungsten-discovery-{unique}"));
        let environment = DiscoveryEnvironment {
            program_files: root.join("Program Files"),
            appdata: Some(root.join("AppData/Roaming")),
            program_data: root.join("ProgramData"),
            local_app_data: Some(root.join("AppData/Local")),
            home: Some(root.join("Home")),
            explicit_home: None,
            requested_product: None,
        };
        (root, environment)
    }

    fn touch(path: &Path) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, "").unwrap();
    }

    #[test]
    fn default_prefers_paid_product_and_latest_version() {
        let (root, environment) = fixture();
        let paid = environment
            .program_files
            .join("Wolfram Research/Wolfram/15.0");
        let older_paid = environment
            .program_files
            .join("Wolfram Research/Wolfram/14.2");
        let engine = environment
            .program_files
            .join("Wolfram Research/Wolfram Engine/14.3");
        touch(&paid.join("wolfram.exe"));
        touch(&older_paid.join("wolfram.exe"));
        touch(&engine.join("wolfram.exe"));
        touch(&environment.program_data.join("Wolfram/Licensing/mathpass"));
        let installation = discover_installation_in(&environment);
        assert_eq!(installation.product, "Wolfram");
        assert_eq!(installation.version.as_deref(), Some("15.0"));
        assert_eq!(
            installation.install_dir.as_deref(),
            paid.canonicalize().ok().as_deref()
        );
        assert_eq!(
            installation
                .available_installations
                .iter()
                .map(|item| (item.product_family.as_str(), item.version.as_deref()))
                .collect::<Vec<_>>(),
            [
                ("wolfram", Some("15.0")),
                ("wolfram", Some("14.2")),
                ("engine", Some("14.3"))
            ]
        );
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn product_override_selects_engine_and_engine_license() {
        let (root, mut environment) = fixture();
        let paid = environment
            .program_files
            .join("Wolfram Research/Wolfram/15.0");
        let engine = environment
            .program_files
            .join("Wolfram Research/Wolfram Engine/14.3");
        touch(&paid.join("wolfram.exe"));
        touch(&engine.join("wolfram.exe"));
        let mathpass = environment
            .appdata
            .as_ref()
            .unwrap()
            .join("WolframEngine/Licensing/mathpass");
        touch(&mathpass);
        environment.requested_product = Some("engine".into());
        let installation = discover_installation_in(&environment);
        assert_eq!(installation.product, "Wolfram Engine");
        assert_eq!(
            installation.install_dir.as_deref(),
            engine.canonicalize().ok().as_deref()
        );
        assert_eq!(installation.mathpass.as_deref(), Some(mathpass.as_path()));
        fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn docs_filter_update_version_and_include_common_docs() {
        let (root, environment) = fixture();
        let install = root.join("Wolfram/14.3");
        fs::create_dir_all(&install).unwrap();
        let current =
            environment.appdata.as_ref().unwrap().join(
                "Wolfram/Paclets/Repository/SystemDocsUpdate3-14.3.0.3/Documentation/English",
            );
        let stale =
            environment.appdata.as_ref().unwrap().join(
                "Wolfram/Paclets/Repository/SystemDocsUpdate2-14.2.0.2/Documentation/English",
            );
        let common = environment.program_files.join(
            "Common Files/Wolfram Research/Documentation.en-us/14.3/Documentation/English/System",
        );
        fs::create_dir_all(&current).unwrap();
        fs::create_dir_all(stale).unwrap();
        fs::create_dir_all(&common).unwrap();
        assert_eq!(
            discover_docs_roots_in(Some(&install), None, &environment),
            [
                current.canonicalize().unwrap(),
                common.canonicalize().unwrap()
            ]
        );
        fs::remove_dir_all(root).unwrap();
    }
}
