use std::ffi::OsString;
use std::path::PathBuf;

use clap::{CommandFactory, Parser, Subcommand};

#[derive(Debug, Parser)]
#[command(
    name = "tecs",
    version,
    about = "A typed entity component system and the engine around it",
    subcommand_required = true
)]
pub struct Cli {
    #[command(subcommand)]
    pub command: Command,
}

#[derive(Debug, Subcommand)]
pub enum Command {
    /// Scaffold a project.
    New {
        /// Directory to create.
        directory: PathBuf,

        /// Overwrite an existing project.
        #[arg(long)]
        force: bool,
    },

    /// Type-check the project.
    Check {
        /// Sources to check; defaults to the project's source directory.
        paths: Vec<PathBuf>,
    },

    /// Format the project.
    Format {
        /// Report unformatted files without writing them.
        #[arg(long)]
        check: bool,

        /// Files or directories to format.
        paths: Vec<PathBuf>,
    },

    /// Compile and run the project's specs.
    Test,

    /// Compile sources and stage assets.
    Build,

    /// Build and launch the game.
    Run,

    /// Remove the project's build output.
    Clean,

    /// Print versions, pinned revisions, project details, and targets.
    Info,

    /// Run the embedded Teal compiler in a child process.
    #[command(name = "__teal", hide = true)]
    Teal {
        #[arg(trailing_var_arg = true, allow_hyphen_values = true)]
        arguments: Vec<OsString>,
    },
}

pub fn help() -> Vec<u8> {
    Cli::command().render_long_help().to_string().into_bytes()
}

#[cfg(test)]
mod tests {
    use clap::Parser;

    use super::{help, Cli, Command};

    #[test]
    fn parses_the_current_public_command_shape() {
        let parsed = Cli::try_parse_from(["tecs", "new", "game", "--force"]).unwrap();
        match parsed.command {
            Command::New { directory, force } => {
                assert_eq!(directory.to_str(), Some("game"));
                assert!(force);
            }
            command => panic!("parsed the wrong command: {command:?}"),
        }

        let parsed = Cli::try_parse_from(["tecs", "format", "--check", "src", "spec"]).unwrap();
        match parsed.command {
            Command::Format { check, paths } => {
                assert!(check);
                assert_eq!(paths.len(), 2);
            }
            command => panic!("parsed the wrong command: {command:?}"),
        }
    }

    #[test]
    fn public_help_lists_public_commands_but_not_the_internal_one() {
        let help = String::from_utf8(help()).unwrap();
        for command in [
            "new", "check", "format", "test", "build", "run", "clean", "info",
        ] {
            assert!(help.contains(command), "help does not name {command}");
        }
        assert!(help.contains("--version"));
        assert!(!help.contains("__teal"));
    }
}
