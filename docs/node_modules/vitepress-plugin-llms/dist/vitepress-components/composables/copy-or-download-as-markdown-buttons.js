// Built with bunup (https://bunup.dev)
import {
  downloadFile,
  resolveMarkdownPageURL
} from "../../shared/chunk-khtqr6em.js";

// src/vitepress-components/composables/copy-or-download-as-markdown-buttons.ts
import { onMounted, ref } from "vue";
var defaultAnimationDuration = 2000;
var defaultAiProviders = [
  { name: "ChatGPT", url: "https://chatgpt.com/?hints=search&prompt=" },
  { name: "Claude", url: "https://claude.ai/new?q=" }
];
var fetchMarkdown = async (markdownPageURL) => {
  const response = await fetch(markdownPageURL);
  return response.text();
};
var resolveMarkdownFilename = (markdownPageURL) => markdownPageURL.split("/").pop() ?? "page.md";
var scheduleReset = (state, animationDuration) => {
  setTimeout(() => {
    state.value = false;
  }, animationDuration);
};
function useCopyOrDownloadAsMarkdownButtons(options = {}) {
  const aiProviders = options.aiProviders ?? defaultAiProviders;
  const animationDuration = options.animationDuration ?? defaultAnimationDuration;
  const copied = ref(false);
  const downloaded = ref(false);
  const currentURL = ref("");
  const markdownPageURL = ref("");
  onMounted(() => {
    currentURL.value = options.currentURL ?? globalThis.location.origin + globalThis.location.pathname;
    markdownPageURL.value = resolveMarkdownPageURL(currentURL.value);
  });
  async function copyAsMarkdown() {
    try {
      const text = await fetchMarkdown(markdownPageURL.value);
      await navigator.clipboard.writeText(text);
      copied.value = true;
    } catch (error) {
      console.error("❌ Error:", error);
    } finally {
      scheduleReset(copied, animationDuration);
    }
  }
  async function downloadMarkdown() {
    try {
      const text = await fetchMarkdown(markdownPageURL.value);
      const filename = resolveMarkdownFilename(markdownPageURL.value);
      downloadFile(filename, text, "text/markdown");
      downloaded.value = true;
    } catch (error) {
      console.error("❌ Error:", error);
    } finally {
      scheduleReset(downloaded, animationDuration);
    }
  }
  function viewAsMarkdown() {
    window.open(markdownPageURL.value, "_blank");
  }
  function openInAI(provider) {
    const prompt = `Read from ${markdownPageURL.value} so I can ask questions about it.`;
    window.open(provider.url + encodeURIComponent(prompt), "_blank");
  }
  return {
    aiProviders,
    copied,
    copyAsMarkdown,
    currentURL,
    downloadMarkdown,
    downloaded,
    markdownPageURL,
    openInAI,
    viewAsMarkdown
  };
}
export {
  useCopyOrDownloadAsMarkdownButtons,
  defaultAiProviders
};
