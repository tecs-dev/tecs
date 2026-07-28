import { defineConfig } from "vitepress";
import llmstxt from "vitepress-plugin-llms";
// Local Teal TextMate grammar (teal-language/vscode-teal). Bundled into the
// build; registering it here adds `teal`/`tl` highlighting with no upstream PR.
import tealGrammar from "./teal.tmLanguage.json";

// Map a page's source path to the generated LLM-friendly Markdown URL.
// "ecs/index.md" -> "/ecs.md", "ecs/world.md" -> "/ecs/world.md".
// Returns null for the site homepage (no per-page Markdown is emitted).
function mdSourceUrl(relativePath: string): string | null {
    if (relativePath === "index.md") return null;
    const clean = relativePath
        .replace(/(^|\/)index\.md$/, "$1")
        .replace(/\.md$/, "")
        .replace(/\/$/, "");
    return `/${clean}.md`;
}

// https://vitepress.dev/reference/site-config
export default defineConfig({
    title: "Tecs",
    description: "Typed entity component system and game engine for Lua.",
    vite: {
        plugins: [
            llmstxt({
                description: "Typed entity component system and game engine for Lua.",
                details:
                    "Tecs is a typed entity component system for LuaJIT and the game engine built " +
                    "around it, written in Teal. The ECS knows what the GPU reads, so rendering is not a " +
                    "layer bolted on top of a renderer-agnostic core. SDL owns the loop: an entry file " +
                    "returns an application and a C host drives it.",
            }),
        ],
    },
    markdown: {
        theme: {
            light: "github-light-high-contrast",
            dark: "tokyo-night",
        },
        languages: [{ ...(tealGrammar as any), name: "teal", aliases: ["tl"] }],
        // A page is compiled as a Vue template, so `{{ ... }}` inside inline
        // code is read as an interpolation and rendered as whatever the
        // expression evaluates to, which for a type like `{{string, string}}`
        // is nothing. Fenced blocks are already given `v-pre`; inline code is
        // not, and a signature that quietly loses an argument is exactly the
        // kind of confidently wrong reference this site is meant not to carry.
        config(md) {
            const renderInline = md.renderer.rules.code_inline;
            md.renderer.rules.code_inline = (tokens, index, options, env, self) => {
                tokens[index].attrSet("v-pre", "");
                return renderInline
                    ? renderInline(tokens, index, options, env, self)
                    : self.renderToken(tokens, index, options);
            };
        },
    },
    head: [
        ["link", { rel: "icon", type: "image/svg+xml", href: "/images/logo.svg" }],
        ["link", { rel: "preconnect", href: "https://fonts.googleapis.com" }],
        ["link", { rel: "preconnect", href: "https://fonts.gstatic.com", crossorigin: "" }],
        ["link", { href: "https://fonts.googleapis.com/css2?family=Jersey+15&display=swap", rel: "stylesheet" }],
    ],
    // Advertise the LLM-friendly Markdown source of each page.
    transformHead({ pageData }) {
        const href = mdSourceUrl(pageData.relativePath);
        if (!href) return;
        return [["link", { rel: "alternate", type: "text/markdown", href }]];
    },
    themeConfig: {
        // https://vitepress.dev/reference/default-theme-config

        siteTitle: "Tecs",

        search: {
            provider: "local",
        },

        nav: [
            { text: "Get started", link: "/getting-started" },
            { text: "Surface", link: "/modules/" },
            { text: "tecs.ecs", link: "/ecs/" },
            { text: "CLI", link: "/cli/" },
        ],

        sidebar: [
            {
                text: "Introduction",
                collapsed: false,
                items: [
                    { text: "Getting started", link: "/getting-started" },
                    { text: "Modules", link: "/modules/" },
                    { text: "Tecs CLI", link: "/cli/" },
                ],
            },
            // Flat, alphabetical ignoring case, and spelled the way a game
            // writes it. A reader looking for `tecs.watch` scans for that
            // string; a thematic grouping makes them guess which of four
            // headings somebody filed it under first, and a collapsed group
            // hides the name entirely until they guess right. Where two names
            // differ only in case the capitalised one comes first, so
            // `tecs.Application` sits above `tecs.application`.
            //
            // Every field on the surface is here, not only the ones with a
            // page of their own under /modules/, because a reader does not
            // know which half a name belongs to and should not have to. The
            // order matches docs/modules/index.md and the home page exactly.
            {
                text: "Modules",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/modules/" },
                    { text: "Generated signatures", link: "/modules/surface" },
                    { text: "tecs.animation", link: "/modules/animation" },
                    { text: "tecs.Application", link: "/modules/Application" },
                    { text: "tecs.application", link: "/modules/Application" },
                    { text: "tecs.assets", link: "/modules/assets" },
                    { text: "tecs.Audio", link: "/modules/Audio" },
                    { text: "tecs.audio", link: "/modules/Audio#physical-devices-and-microphone-capture" },
                    { text: "tecs.builtins", link: "/ecs/builtins" },
                    { text: "tecs.Camera", link: "/modules/Camera" },
                    { text: "tecs.capabilities", link: "/modules/capabilities" },
                    { text: "tecs.clipboard", link: "/modules/clipboard" },
                    { text: "tecs.clock", link: "/modules/clock" },
                    { text: "tecs.componentByName", link: "/ecs/components/" },
                    { text: "tecs.components", link: "/modules/components" },
                    { text: "tecs.compress", link: "/modules/compress" },
                    { text: "tecs.DEFAULT_MAX_ENTITIES", link: "/ecs/world" },
                    { text: "tecs.dialogs", link: "/modules/dialogs" },
                    { text: "tecs.events", link: "/modules/events" },
                    { text: "tecs.filesystem", link: "/modules/filesystem" },
                    { text: "tecs.findKey", link: "/ecs/world" },
                    { text: "tecs.Future", link: "/modules/Future" },
                    { text: "tecs.Gamepad", link: "/modules/Gamepad" },
                    { text: "tecs.getComponentById", link: "/ecs/components/" },
                    { text: "tecs.hash", link: "/modules/hash" },
                    { text: "tecs.http", link: "/modules/http" },
                    { text: "tecs.Input", link: "/modules/Input" },
                    { text: "tecs.json", link: "/modules/json" },
                    { text: "tecs.layers", link: "/modules/layers" },
                    { text: "tecs.listKeys", link: "/ecs/world" },
                    { text: "tecs.log", link: "/modules/log" },
                    { text: "tecs.materials", link: "/modules/materials" },
                    { text: "tecs.MAX_ENTITIES", link: "/ecs/world" },
                    { text: "tecs.mcp", link: "/modules/mcp" },
                    { text: "tecs.net", link: "/modules/net" },
                    { text: "tecs.newComponent", link: "/ecs/components/table-components" },
                    { text: "tecs.newContext", link: "/ecs/world" },
                    { text: "tecs.newEvent", link: "/ecs/events" },
                    { text: "tecs.newFFIComponent", link: "/ecs/components/ffi" },
                    { text: "tecs.newFFIEvent", link: "/ecs/events" },
                    { text: "tecs.newFFIRelationship", link: "/ecs/relationships/ffi" },
                    { text: "tecs.newKey", link: "/ecs/world" },
                    { text: "tecs.newMessageBus", link: "/ecs/events" },
                    { text: "tecs.newRelationship", link: "/ecs/relationships/" },
                    { text: "tecs.newScalarComponent", link: "/ecs/components/scalar-components" },
                    { text: "tecs.newTagComponent", link: "/ecs/components/tag-components" },
                    { text: "tecs.newWorld", link: "/ecs/world" },
                    { text: "tecs.particles", link: "/modules/particles" },
                    { text: "tecs.paths", link: "/modules/paths" },
                    { text: "tecs.phases", link: "/ecs/phases" },
                    { text: "tecs.physics", link: "/modules/physics" },
                    { text: "tecs.proc", link: "/modules/proc" },
                    { text: "tecs.random", link: "/modules/random" },
                    { text: "tecs.Renderer", link: "/modules/Renderer" },
                    { text: "tecs.runif", link: "/ecs/systems" },
                    { text: "tecs.sensors", link: "/modules/sensors" },
                    { text: "tecs.sequence", link: "/modules/sequence" },
                    { text: "tecs.sheet", link: "/modules/sheet" },
                    { text: "tecs.system", link: "/modules/system" },
                    { text: "tecs.text", link: "/modules/text" },
                    { text: "tecs.version", link: "/modules/surface" },
                    { text: "tecs.watch", link: "/modules/watch" },
                    { text: "tecs.Window", link: "/modules/Window" },
                    { text: "tecs.workers", link: "/modules/workers" },
                ],
            },
            // The concept pages, under the module that actually holds the ECS
            // half rather than under an invented category. `tecs.ecs` is what
            // engine code requires; a game requires `tecs` and reaches the
            // same things through the list above, which the section says in
            // its first paragraph so the heading does not mislead.
            //
            // Alphabetical, with each section's own overview first.
            {
                text: "tecs.ecs",
                collapsed: false,
                items: [
                    { text: "Overview", link: "/ecs/" },
                    { text: "Archetypes", link: "/ecs/archetype" },
                    { text: "Builtins", link: "/ecs/builtins" },
                    {
                        text: "Components",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/components/" },
                            { text: "Bundles", link: "/ecs/components/bundles" },
                            { text: "Construction", link: "/ecs/components/construction" },
                            { text: "Dirty tracking", link: "/ecs/components/dirty-tracking" },
                            { text: "FFI components", link: "/ecs/components/ffi" },
                            { text: "Scalar components", link: "/ecs/components/scalar-components" },
                            { text: "Serialization", link: "/ecs/components/serialization" },
                            { text: "Table components", link: "/ecs/components/table-components" },
                            { text: "Tag components", link: "/ecs/components/tag-components" },
                        ],
                    },
                    { text: "Events", link: "/ecs/events" },
                    { text: "Mutation model", link: "/ecs/mutation-model" },
                    { text: "Phases", link: "/ecs/phases" },
                    { text: "Plugins", link: "/ecs/plugins" },
                    { text: "Profiling", link: "/ecs/profiling" },
                    {
                        text: "Queries",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/queries/" },
                            { text: "Callbacks", link: "/ecs/queries/callbacks" },
                            { text: "Grouping", link: "/ecs/queries/grouping" },
                        ],
                    },
                    {
                        text: "Relationships",
                        collapsed: true,
                        items: [
                            { text: "Overview", link: "/ecs/relationships/" },
                            { text: "FFI relationships", link: "/ecs/relationships/ffi" },
                        ],
                    },
                    { text: "Save games", link: "/ecs/save-games" },
                    { text: "States", link: "/ecs/states" },
                    { text: "Systems", link: "/ecs/systems" },
                    { text: "World", link: "/ecs/world" },
                ],
            },
        ],

        socialLinks: [{ icon: "github", link: "https://github.com/tecs-dev/tecs" }],

        footer: {
            message:
                'Tecs code is released under the <a href="https://github.com/tecs-dev/tecs/blob/main/LICENSE-MIT">MIT</a> ' +
                'or <a href="https://github.com/tecs-dev/tecs/blob/main/LICENSE-APACHE">Apache-2.0</a> license, at your option. ' +
                '<a href="https://github.com/tecs-dev/tecs/blob/main/THIRD_PARTY_NOTICES.md">Third-party notices</a>. ' +
                'For LLMs: <a href="/llms.txt">llms.txt</a> · <a href="/llms-full.txt">llms-full.txt</a>.',
            copyright: 'Copyright © <a href="https://github.com/mtdowling">Michael Dowling</a>',
        },
    },
});
