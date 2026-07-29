use std::fs;
use std::path::{Path, PathBuf};

#[derive(Debug, Eq, PartialEq)]
pub struct Output {
    pub code: i32,
    pub stderr: bool,
    pub text: String,
}

#[derive(Debug)]
struct Symbol {
    name: String,
    markdown: String,
}

#[derive(Debug)]
struct Page {
    path: String,
    title: String,
    description: String,
    narrative: String,
    symbols: Vec<Symbol>,
}

#[derive(Debug)]
struct Reference {
    pages: Vec<Page>,
}

#[derive(Clone, Copy, Debug)]
enum Match<'a> {
    Page(&'a Page),
    Symbol(&'a Page, &'a Symbol),
}

impl Page {
    fn parse(path: String, markdown: String) -> Self {
        let description = markdown
            .lines()
            .find_map(|line| {
                line.trim()
                    .strip_prefix("description:")
                    .map(|value| value.trim().trim_matches(['"', '\'']).to_owned())
            })
            .unwrap_or_default();
        let body = without_frontmatter(&markdown);
        let title = body
            .lines()
            .find_map(|line| line.strip_prefix("# ").map(clean_heading))
            .unwrap_or_else(|| {
                if path == "index.md" {
                    "Tecs".to_owned()
                } else {
                    path.trim_end_matches(".md")
                        .rsplit('/')
                        .next()
                        .unwrap_or("Reference")
                        .replace('-', " ")
                }
            });
        let narrative = body
            .split("<!-- @generated ")
            .next()
            .unwrap_or(body)
            .to_owned();

        let lines: Vec<_> = body.lines().collect();
        let mut symbols = Vec::new();
        for (index, line) in lines.iter().enumerate() {
            let Some(heading) = line.strip_prefix("### ") else {
                continue;
            };
            let name = clean_heading(heading);
            if !name.starts_with("tecs.") {
                continue;
            }
            let end = lines[index + 1..]
                .iter()
                .position(|candidate| candidate.starts_with("### "))
                .map_or(lines.len(), |offset| index + 1 + offset);
            symbols.push(Symbol {
                name,
                markdown: lines[index..end].join("\n"),
            });
        }

        Self {
            path,
            title,
            description,
            narrative,
            symbols,
        }
    }

    fn aliases(&self) -> impl Iterator<Item = String> + '_ {
        let lower_title = self.title.to_lowercase();
        let route = self.path.trim_end_matches(".md").to_lowercase();
        let basename = route.rsplit('/').next().unwrap_or(&route).to_owned();
        [
            lower_title.clone(),
            lower_title
                .strip_prefix("tecs.")
                .unwrap_or(&lower_title)
                .to_owned(),
            route.replace('/', "."),
            basename,
        ]
        .into_iter()
    }
}

impl Reference {
    fn load(directory: &Path) -> Result<Self, String> {
        if !directory.is_dir() {
            return Err(format!(
                "offline reference is missing from {}",
                directory.display()
            ));
        }
        let mut files = Vec::new();
        collect_markdown(directory, directory, &mut files)?;
        files.sort();
        let pages = files
            .into_iter()
            .map(|path| {
                let relative = path
                    .strip_prefix(directory)
                    .expect("collected path is below the documentation root")
                    .to_string_lossy()
                    .replace('\\', "/");
                let markdown = fs::read_to_string(&path)
                    .map_err(|error| format!("cannot read {}: {error}", path.display()))?;
                Ok(Page::parse(relative, markdown))
            })
            .collect::<Result<Vec<_>, String>>()?;
        if pages.is_empty() {
            return Err(format!(
                "offline reference has no pages in {}",
                directory.display()
            ));
        }
        Ok(Self { pages })
    }

    #[cfg(test)]
    fn from_sources(sources: &[(&str, &str)]) -> Self {
        Self {
            pages: sources
                .iter()
                .map(|(path, markdown)| Page::parse((*path).into(), (*markdown).into()))
                .collect(),
        }
    }

    fn index(&self) -> String {
        let mut api: Vec<_> = self
            .pages
            .iter()
            .filter(|page| page.title.starts_with("tecs"))
            .collect();
        let mut guides: Vec<_> = self
            .pages
            .iter()
            .filter(|page| !page.title.starts_with("tecs") && page.title != "Tecs")
            .collect();
        api.sort_by_key(|page| page.title.to_lowercase());
        guides.sort_by_key(|page| page.title.to_lowercase());

        let mut output = String::from(
            "Tecs offline reference\n\n\
             Usage: tecs docs [QUERY]\n\n\
             Query a topic such as `physics` or an API name such as\n\
             `tecs.physics.attach`.\n",
        );
        append_index_group(&mut output, "API", &api);
        append_index_group(&mut output, "Guides", &guides);
        output
    }

    fn exact(&self, query: &str) -> Vec<Match<'_>> {
        let pages: Vec<_> = self
            .pages
            .iter()
            .filter(|page| page.aliases().any(|alias| alias == query))
            .map(Match::Page)
            .collect();
        if !pages.is_empty() {
            return pages;
        }

        let mut matches = Vec::new();
        for page in &self.pages {
            for symbol in &page.symbols {
                if symbol.name.eq_ignore_ascii_case(query) {
                    matches.push(Match::Symbol(page, symbol));
                }
            }
        }
        matches
    }

    fn search(&self, query: &str) -> Vec<Match<'_>> {
        let mut matches = Vec::new();
        for page in &self.pages {
            if page.title.to_lowercase().contains(query)
                || page.description.to_lowercase().contains(query)
                || page.path.to_lowercase().contains(query)
            {
                matches.push(Match::Page(page));
            }
            for symbol in &page.symbols {
                if symbol.name.to_lowercase().contains(query) {
                    matches.push(Match::Symbol(page, symbol));
                }
            }
        }
        matches
    }
}

pub fn render(directory: &Path, query: Option<&str>) -> Output {
    let reference = match Reference::load(directory) {
        Ok(reference) => reference,
        Err(reason) => {
            return Output {
                code: 1,
                stderr: true,
                text: format!("tecs docs: {reason}\n"),
            };
        }
    };
    render_reference(&reference, query)
}

fn render_reference(reference: &Reference, query: Option<&str>) -> Output {
    let Some(query) = query.map(str::trim).filter(|query| !query.is_empty()) else {
        return Output {
            code: 0,
            stderr: false,
            text: reference.index(),
        };
    };
    let normalized = query.to_lowercase();
    let exact = reference.exact(&normalized);
    if exact.len() == 1 {
        return Output {
            code: 0,
            stderr: false,
            text: render_match(exact[0]),
        };
    }
    if exact.len() > 1 {
        return ambiguous(query, &exact);
    }

    let matches = reference.search(&normalized);
    match matches.as_slice() {
        [] => Output {
            code: 1,
            stderr: true,
            text: format!(
                "tecs docs: no match for `{query}`\n\
                 Run `tecs docs` to list the offline reference.\n"
            ),
        },
        [found] => Output {
            code: 0,
            stderr: false,
            text: render_match(*found),
        },
        _ => ambiguous(query, &matches),
    }
}

fn ambiguous(query: &str, matches: &[Match<'_>]) -> Output {
    let mut output = format!("Multiple matches for `{query}`:\n\n");
    for found in matches.iter().take(40) {
        let (label, description) = match found {
            Match::Page(page) => (&page.title, page.description.as_str()),
            Match::Symbol(page, symbol) => (&symbol.name, page.description.as_str()),
        };
        output.push_str("  ");
        output.push_str(label);
        if !description.is_empty() {
            output.push_str(" — ");
            output.push_str(description);
        }
        output.push('\n');
    }
    if matches.len() > 40 {
        output.push_str(&format!("  … and {} more\n", matches.len() - 40));
    }
    output.push_str("\nUse a more specific page or fully-qualified API name.\n");
    Output {
        code: 2,
        stderr: false,
        text: output,
    }
}

fn render_match(found: Match<'_>) -> String {
    match found {
        Match::Page(page) => {
            let mut output = render_markdown(&page.narrative);
            if !page.symbols.is_empty() {
                output.push_str("\nReference symbols\n\n");
                for symbol in &page.symbols {
                    output.push_str("  ");
                    output.push_str(&symbol.name);
                    output.push('\n');
                }
            }
            output
        }
        Match::Symbol(_, symbol) => render_markdown(&symbol.markdown),
    }
}

fn append_index_group(output: &mut String, heading: &str, pages: &[&Page]) {
    if pages.is_empty() {
        return;
    }
    output.push('\n');
    output.push_str(heading);
    output.push_str("\n\n");
    for page in pages {
        output.push_str("  ");
        output.push_str(&page.title);
        if !page.description.is_empty() {
            output.push_str(" — ");
            output.push_str(&page.description);
        }
        output.push('\n');
    }
}

fn collect_markdown(
    root: &Path,
    directory: &Path,
    output: &mut Vec<PathBuf>,
) -> Result<(), String> {
    let entries = fs::read_dir(directory)
        .map_err(|error| format!("cannot read {}: {error}", directory.display()))?;
    for entry in entries {
        let entry =
            entry.map_err(|error| format!("cannot read {}: {error}", directory.display()))?;
        let path = entry.path();
        let kind = entry
            .file_type()
            .map_err(|error| format!("cannot inspect {}: {error}", path.display()))?;
        if kind.is_dir() {
            if entry.file_name() != "node_modules" {
                collect_markdown(root, &path, output)?;
            }
        } else if kind.is_file() && path.extension().and_then(|value| value.to_str()) == Some("md")
        {
            debug_assert!(path.starts_with(root));
            output.push(path);
        }
    }
    Ok(())
}

fn without_frontmatter(markdown: &str) -> &str {
    let Some(rest) = markdown.strip_prefix("---\n") else {
        return markdown;
    };
    rest.split_once("\n---\n")
        .map_or(markdown, |(_, body)| body)
}

fn clean_heading(heading: &str) -> String {
    heading
        .split_once(" {#")
        .map_or(heading, |(text, _)| text)
        .trim()
        .to_owned()
}

fn render_markdown(markdown: &str) -> String {
    let mut output = String::new();
    let mut in_code = false;
    let mut blank = true;
    for raw in markdown.lines() {
        let trimmed = raw.trim();
        if trimmed.starts_with("```") {
            in_code = !in_code;
            if !blank {
                output.push('\n');
            }
            blank = true;
            continue;
        }
        if trimmed.starts_with(":::")
            || (trimmed.starts_with("<a id=") && trimmed.ends_with("</a>"))
        {
            continue;
        }
        let mut line = if in_code {
            format!("    {raw}")
        } else {
            raw.trim_start_matches('#').trim_start().to_owned()
        };
        line = strip_html(&line)
            .replace("&lt;", "<")
            .replace("&gt;", ">")
            .replace("&amp;", "&");
        if line.trim().is_empty() {
            if !blank {
                output.push('\n');
                blank = true;
            }
            continue;
        }
        output.push_str(line.trim_end());
        output.push('\n');
        blank = false;
    }
    while output.ends_with("\n\n") {
        output.pop();
    }
    if !output.ends_with('\n') {
        output.push('\n');
    }
    output
}

fn strip_html(line: &str) -> String {
    let mut output = String::with_capacity(line.len());
    let mut remaining = line;
    while let Some(start) = remaining.find('<') {
        output.push_str(&remaining[..start]);
        let candidate = &remaining[start..];
        let html = [
            "<a ", "<a>", "</a>", "<pre", "</pre>", "<code", "</code>", "<span", "</span>",
        ]
        .iter()
        .any(|prefix| candidate.starts_with(prefix));
        if html {
            if let Some(end) = candidate.find('>') {
                remaining = &candidate[end + 1..];
                continue;
            }
        }
        output.push('<');
        remaining = &candidate[1..];
    }
    output.push_str(remaining);
    output
}

#[cfg(test)]
mod tests {
    use super::{render_reference, Reference};

    const PHYSICS: &str = r##"---
description: "Rigid bodies and queries"
---

# tecs.physics

Physics narrative.

<!-- @generated by a test. -->

## Reference

<a id="tecs.physics.attach"></a>

### tecs.physics.attach

<pre><code v-pre>function <a href="#tecs.physics.attach">tecs.physics.attach</a>(world: World)
</code></pre>

Attaches a body.

#### Parameters

The world to change.

### tecs.physics.detach

Detaches a body.
"##;

    const WORLD: &str = r#"---
description: "Entities, resources, and state"
---

# World

World narrative.
"#;

    fn reference() -> Reference {
        Reference::from_sources(&[("modules/physics.md", PHYSICS), ("ecs/world.md", WORLD)])
    }

    #[test]
    fn index_lists_pages_and_descriptions() {
        let output = render_reference(&reference(), None);
        assert_eq!(output.code, 0);
        assert!(!output.stderr);
        assert!(output
            .text
            .contains("tecs.physics — Rigid bodies and queries"));
        assert!(output
            .text
            .contains("World — Entities, resources, and state"));
    }

    #[test]
    fn short_page_alias_renders_narrative_and_symbol_index() {
        let output = render_reference(&reference(), Some("physics"));
        assert_eq!(output.code, 0);
        assert!(output.text.contains("Physics narrative."));
        assert!(!output.text.contains("Attaches a body."));
        assert!(output.text.contains("tecs.physics.attach"));
    }

    #[test]
    fn markdown_rendering_keeps_teal_type_annotations() {
        let reference = Reference::from_sources(&[(
            "guide.md",
            "---\ndescription: \"Guide\"\n---\n# Guide\n\n`local value <const> = 1`\n",
        )]);
        let output = render_reference(&reference, Some("guide"));
        assert!(output.text.contains("<const>"));
    }

    #[test]
    fn fully_qualified_name_renders_only_its_reference() {
        let output = render_reference(&reference(), Some("tecs.physics.attach"));
        assert_eq!(output.code, 0);
        assert!(output
            .text
            .contains("function tecs.physics.attach(world: World)"));
        assert!(output.text.contains("The world to change."));
        assert!(!output.text.contains("tecs.physics.detach"));
    }

    #[test]
    fn ambiguous_and_missing_queries_have_actionable_statuses() {
        let ambiguous = render_reference(&reference(), Some("physics."));
        assert_eq!(ambiguous.code, 2);
        assert!(!ambiguous.stderr);
        assert!(ambiguous.text.contains("Use a more specific"));

        let missing = render_reference(&reference(), Some("spaceship"));
        assert_eq!(missing.code, 1);
        assert!(missing.stderr);
        assert!(missing.text.contains("Run `tecs docs`"));
    }
}
