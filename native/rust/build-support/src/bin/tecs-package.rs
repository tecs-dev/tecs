use anyhow::Result;
use clap::{Parser, Subcommand};
use std::env;
use std::path::PathBuf;
use tecs_build_support::{
    package::{self, Preset},
    repository_root,
};

#[derive(Debug, Parser)]
#[command(
    name = "tecs-package",
    bin_name = "nupp task",
    about = "Package Tecs native releases"
)]
struct Arguments {
    #[command(subcommand)]
    command: Task,
}

#[derive(Debug, Subcommand)]
enum Task {
    Presets,
    Package {
        #[arg(long)]
        preset: Option<Preset>,
        #[arg(long = "component")]
        components: Vec<String>,
    },
    CheckPackage {
        #[arg(default_value = package::OUTPUT)]
        prefix: PathBuf,
    },
    TestPackage {
        #[arg(long)]
        preset: Option<Preset>,
    },
}

fn main() -> Result<()> {
    let args = Arguments::parse();
    let root = repository_root(&env::current_dir()?)?;
    match args.command {
        Task::Presets => package::list(),
        Task::Package { preset, components } => {
            let prefix = package::install(
                &root,
                preset.map_or_else(package::host_default, Ok)?,
                &components,
            )?;
            println!("installed {}", prefix.display());
        }
        Task::CheckPackage { prefix } => package::check(&root.join(prefix))?,
        Task::TestPackage { preset } => {
            package::test(&root, preset.map_or_else(package::host_default, Ok)?)?
        }
    }
    Ok(())
}
