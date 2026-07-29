import { Ref } from "vue";
type MarkdownAiProviders = readonly MarkdownAiProvider[];
/**
* Represents an AI provider that can open the current page as Markdown.
*/
interface MarkdownAiProvider {
	/** Display name of the provider, e.g. `'ChatGPT'`. */
	readonly name: string;
	/**
	* Base URL used to open the provider with a pre-filled prompt.
	* The encoded prompt string will be appended directly to this URL.
	*
	* @example 'https://claude.ai/new?q='
	*/
	readonly url: string;
}
/**
* The default list of AI providers bundled with the plugin:
* **ChatGPT** and **Claude**.
*
* Pass this to {@link UseCopyOrDownloadAsMarkdownButtonsOptions.aiProviders}
* as a base when you want to extend rather than replace the defaults.
*
* @example
* ```ts
* useCopyOrDownloadAsMarkdownButtons({
*   aiProviders: [
*     ...defaultAiProviders,
*     { name: 'Gemini', url: 'https://gemini.google.com/app?q=' },
*   ],
* })
* ```
*/
declare const defaultAiProviders: readonly [{
	readonly name: "ChatGPT";
	readonly url: "https://chatgpt.com/?hints=search&prompt=";
}, {
	readonly name: "Claude";
	readonly url: "https://claude.ai/new?q=";
}];
type ResolvedMarkdownAiProviders<Providers extends MarkdownAiProviders | undefined> = Providers extends MarkdownAiProviders ? Providers : typeof defaultAiProviders;
/**
* Options for {@link useCopyOrDownloadAsMarkdownButtons}.
*/
interface UseCopyOrDownloadAsMarkdownButtonsOptions<Providers extends MarkdownAiProviders | undefined = undefined> {
	/**
	* List of AI providers shown in the dropdown.
	* Defaults to {@link defaultAiProviders}.
	*/
	readonly aiProviders?: Providers;
	/**
	* Duration in milliseconds for which the `copied` / `downloaded`
	* state remains `true` after a successful action.
	* Reset scheduling uses this configured value when the composable is created.
	*
	* @default 2000
	*/
	readonly animationDuration?: number;
	/**
	* Override the current page URL used to derive the Markdown file URL.
	* When omitted, `window.location.origin + window.location.pathname` is used.
	*
	* Useful in tests or non-browser environments.
	*/
	readonly currentURL?: string;
}
/**
* Return type of {@link useCopyOrDownloadAsMarkdownButtons}.
*/
interface UseCopyOrDownloadAsMarkdownButtonsReturn<Providers extends MarkdownAiProviders = typeof defaultAiProviders> {
	/** List of AI providers passed via options, or {@link defaultAiProviders} if not specified. */
	aiProviders: Providers;
	/** `true` for {@link UseCopyOrDownloadAsMarkdownButtonsOptions.animationDuration} ms after {@link copyAsMarkdown} succeeds, then reset using that configured duration. */
	copied: Ref<boolean>;
	/** `true` for {@link UseCopyOrDownloadAsMarkdownButtonsOptions.animationDuration} ms after {@link downloadMarkdown} succeeds, then reset using that configured duration. */
	downloaded: Ref<boolean>;
	/**
	* The resolved URL of the current page.
	* Empty string during SSR; populated in `onMounted`.
	*/
	currentURL: Readonly<Ref<string>>;
	/**
	* The resolved URL of the `.md` source file for the current page.
	* Empty string during SSR; populated in `onMounted`.
	*/
	markdownPageURL: Readonly<Ref<string>>;
	/** Fetches the page Markdown and writes it to the clipboard. */
	copyAsMarkdown: () => Promise<void>;
	/** Fetches the page Markdown and triggers a file download. */
	downloadMarkdown: () => Promise<void>;
	/** Opens the raw Markdown source of the current page in a new tab. */
	viewAsMarkdown: () => void;
	/**
	* Opens the given AI provider in a new tab with a pre-filled prompt
	* that instructs it to read the Markdown source of the current page.
	*
	* @param provider - One of the entries from {@link aiProviders}.
	*/
	openInAI: (provider: Readonly<Providers[number]>) => void;
}
/**
* Composable that exposes the core logic of the "Copy / Download as Markdown"
* button group, so you can build a completely custom UI on top of it.
*
* @param options - Optional configuration. See {@link UseCopyOrDownloadAsMarkdownButtonsOptions}.
* @returns Reactive state and action handlers typed as {@link UseCopyOrDownloadAsMarkdownButtonsReturn}.
*
* @example Basic usage — copy button with feedback
* ```vue
* <script setup lang="ts">
* import { useCopyOrDownloadAsMarkdownButtons } from 'vitepress-plugin-llms'
*
* const { copied, copyAsMarkdown } = useCopyOrDownloadAsMarkdownButtons()
* <\/script>
*
* <template>
*   <button @click="copyAsMarkdown">
*     {{ copied ? 'Copied!' : 'Copy as Markdown' }}
*   </button>
* </template>
* ```
*
* @example Custom AI providers
* ```ts
* const { openInAI } = useCopyOrDownloadAsMarkdownButtons({
*   aiProviders: [
*     { name: 'Gemini', url: 'https://gemini.google.com/app?q=' },
*   ],
* })
* ```
*/
declare function useCopyOrDownloadAsMarkdownButtons<const Providers extends MarkdownAiProviders | undefined = undefined>(options?: UseCopyOrDownloadAsMarkdownButtonsOptions<Providers>): UseCopyOrDownloadAsMarkdownButtonsReturn<ResolvedMarkdownAiProviders<Providers>>;
export { useCopyOrDownloadAsMarkdownButtons, defaultAiProviders, UseCopyOrDownloadAsMarkdownButtonsReturn, UseCopyOrDownloadAsMarkdownButtonsOptions, MarkdownAiProvider };
