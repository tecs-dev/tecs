use std::ffi::{c_char, CStr, OsString};
use std::path::PathBuf;
use std::slice;

use clap::{CommandFactory, Parser, Subcommand};

use super::TecsBytes;

#[derive(Debug, Parser)]
#[command(
    name = "tecs",
    version,
    about = "A typed entity component system and the engine around it",
    subcommand_required = true,
    disable_help_subcommand = false,
    after_help = "A project is a directory holding tecs.lua. Every command searches upward for\n\
                  it, so all of them work from anywhere inside a project."
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

    /// Print the version and exit.
    #[command(hide = true)]
    Version,

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

fn push_field(result: &mut Vec<u8>, field: &[u8]) {
    result.extend_from_slice(field);
    result.push(0);
}

fn exit_result(code: i32, stderr: bool, message: &[u8]) -> Vec<u8> {
    let mut result = Vec::with_capacity(message.len() + 24);
    push_field(&mut result, b"exit");
    push_field(&mut result, code.to_string().as_bytes());
    push_field(&mut result, if stderr { b"stderr" } else { b"stdout" });
    push_field(&mut result, message);
    result
}

#[cfg(unix)]
fn os_bytes(value: OsString) -> Vec<u8> {
    use std::os::unix::ffi::OsStringExt;
    value.into_vec()
}

#[cfg(not(unix))]
fn os_bytes(value: OsString) -> Vec<u8> {
    value.to_string_lossy().into_owned().into_bytes()
}

#[cfg(unix)]
fn argument(bytes: &[u8]) -> OsString {
    use std::os::unix::ffi::OsStringExt;
    OsString::from_vec(bytes.to_vec())
}

#[cfg(not(unix))]
fn argument(bytes: &[u8]) -> OsString {
    OsString::from(String::from_utf8_lossy(bytes).into_owned())
}

fn run_result(command: Command) -> Vec<u8> {
    let mut result = Vec::new();
    push_field(&mut result, b"run");

    match command {
        Command::New { directory, force } => {
            push_field(&mut result, b"new");
            push_field(&mut result, &os_bytes(directory.into_os_string()));
            push_field(&mut result, if force { b"true" } else { b"false" });
        }
        Command::Check { paths } => {
            push_field(&mut result, b"check");
            for path in paths {
                push_field(&mut result, &os_bytes(path.into_os_string()));
            }
        }
        Command::Format { check, paths } => {
            push_field(&mut result, b"format");
            push_field(&mut result, if check { b"true" } else { b"false" });
            for path in paths {
                push_field(&mut result, &os_bytes(path.into_os_string()));
            }
        }
        Command::Test => push_field(&mut result, b"test"),
        Command::Build => push_field(&mut result, b"build"),
        Command::Run => push_field(&mut result, b"run"),
        Command::Clean => push_field(&mut result, b"clean"),
        Command::Info => push_field(&mut result, b"info"),
        Command::Version => {
            return exit_result(
                0,
                false,
                Cli::command().render_version().to_string().as_bytes(),
            );
        }
        Command::Teal { arguments } => {
            push_field(&mut result, b"__teal");
            for item in arguments {
                push_field(&mut result, &os_bytes(item));
            }
        }
    }
    result
}

fn parse(arguments: Vec<OsString>) -> Vec<u8> {
    let mut argv = Vec::with_capacity(arguments.len() + 1);
    argv.push(OsString::from("tecs"));
    argv.extend(arguments);

    match Cli::try_parse_from(argv) {
        Ok(cli) => run_result(cli.command),
        Err(error) => {
            let use_stderr = error.use_stderr();
            exit_result(
                error.exit_code(),
                use_stderr,
                error.render().to_string().as_bytes(),
            )
        }
    }
}

/// Parses a command line through Clap and returns a NUL-separated result.
///
/// The first field is `run` or `exit`. A run result carries the normalized
/// command followed by its operands. An exit result carries the status,
/// `stdout` or `stderr`, and Clap's complete display text. The trailing NUL is
/// part of the result so Lua can split every field through one path.
///
/// # Safety
///
/// When `count` is nonzero, `arguments` must address that many pointers. Each
/// pointer must name a NUL-terminated string and remain readable for this call.
#[no_mangle]
pub unsafe extern "C" fn tecsCliParse(
    count: usize,
    arguments: *const *const c_char,
) -> *mut TecsBytes {
    let pointers = if count == 0 {
        &[]
    } else if arguments.is_null() {
        return Box::into_raw(Box::new(TecsBytes {
            bytes: exit_result(2, true, b"tecs: command arguments are null\n").into_boxed_slice(),
        }));
    } else {
        // SAFETY: The caller promises an array containing `count` pointers.
        unsafe { slice::from_raw_parts(arguments, count) }
    };

    let mut args = Vec::with_capacity(count);
    for pointer in pointers {
        if pointer.is_null() {
            return Box::into_raw(Box::new(TecsBytes {
                bytes: exit_result(2, true, b"tecs: a command argument is null\n")
                    .into_boxed_slice(),
            }));
        }
        // SAFETY: Each pointer is promised to name a NUL-terminated string.
        let bytes = unsafe { CStr::from_ptr(*pointer) }.to_bytes();
        args.push(argument(bytes));
    }

    Box::into_raw(Box::new(TecsBytes {
        bytes: parse(args).into_boxed_slice(),
    }))
}

#[cfg(test)]
mod tests {
    use std::ffi::OsString;

    use clap::Parser;

    use super::{help, parse, Cli, Command};

    fn fields(bytes: &[u8]) -> Vec<&[u8]> {
        bytes
            .split(|byte| *byte == 0)
            .filter(|field| !field.is_empty())
            .collect()
    }

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

    #[test]
    fn normalizes_commands_for_the_lua_dispatcher() {
        let parsed = parse(
            ["new", "my game", "--force"]
                .into_iter()
                .map(OsString::from)
                .collect(),
        );
        assert_eq!(
            fields(&parsed),
            vec![&b"run"[..], &b"new"[..], &b"my game"[..], &b"true"[..]]
        );

        let parsed = parse(
            ["format", "src", "spec", "--check"]
                .into_iter()
                .map(OsString::from)
                .collect(),
        );
        assert_eq!(
            fields(&parsed),
            vec![
                &b"run"[..],
                &b"format"[..],
                &b"true"[..],
                &b"src"[..],
                &b"spec"[..]
            ]
        );
    }

    #[test]
    fn returns_clap_output_and_status_without_exiting() {
        let help = parse([OsString::from("--help")].into());
        let output_fields = fields(&help);
        assert_eq!(
            &output_fields[..3],
            [&b"exit"[..], &b"0"[..], &b"stdout"[..]]
        );
        assert!(String::from_utf8_lossy(output_fields[3]).contains("Usage: tecs"));

        let help = parse([OsString::from("help")].into());
        let output_fields = fields(&help);
        assert_eq!(
            &output_fields[..3],
            [&b"exit"[..], &b"0"[..], &b"stdout"[..]]
        );

        let invalid = parse([OsString::from("unknown")].into());
        let output_fields = fields(&invalid);
        assert_eq!(
            &output_fields[..3],
            [&b"exit"[..], &b"2"[..], &b"stderr"[..]]
        );
        assert!(String::from_utf8_lossy(output_fields[3]).contains("unrecognized subcommand"));
    }
}
