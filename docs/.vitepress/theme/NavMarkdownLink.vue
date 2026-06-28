<script setup lang="ts">
import { computed } from 'vue'
import { useData, withBase } from 'vitepress'

const { page } = useData()

// Same mapping as MarkdownPageLink: "tecs/index.md" -> "/tecs.md".
const mdHref = computed(() => {
  const rel = page.value.relativePath
  if (rel === 'index.md') return null
  const clean = rel
    .replace(/(^|\/)index\.md$/, '$1')
    .replace(/\.md$/, '')
    .replace(/\/$/, '')
  return withBase(`/${clean}.md`)
})
</script>

<template>
  <a
    v-if="mdHref"
    class="VPNavBarMarkdown"
    :href="mdHref"
    target="_blank"
    rel="noreferrer"
    title="View this page as Markdown"
    aria-label="View this page as Markdown"
  >
    <svg viewBox="0 0 208 128" width="22" height="22" aria-hidden="true">
      <rect x="5" y="5" width="198" height="118" rx="10"
            fill="none" stroke="currentColor" stroke-width="10" />
      <path fill="currentColor"
            d="M30 98V30h20l20 25 20-25h20v68H90V59L70 84 50 59v39H30zm125 0l-30-33h20V30h20v35h20l-30 33z" />
    </svg>
  </a>
</template>

<style scoped>
.VPNavBarMarkdown {
  display: flex;
  align-items: center;
  color: var(--vp-c-text-2);
  transition: color 0.25s;
}
.VPNavBarMarkdown:hover {
  color: var(--vp-c-text-1);
}
</style>
