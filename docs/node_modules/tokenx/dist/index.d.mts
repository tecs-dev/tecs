//#region src/types.d.ts
/**
* Configuration options for token estimation
*/
interface TokenEstimationOptions {
  /** Default average characters per token when no language-specific rule applies */
  defaultCharsPerToken?: number;
  /** Custom language configurations to override defaults */
  languageConfigs?: LanguageConfig[];
}
/**
* Language-specific token estimation configurations
*/
interface LanguageConfig {
  /** Regular expression to detect the language */
  pattern: RegExp;
  /** Average number of characters per token for this language */
  averageCharsPerToken: number;
}
/**
* Configuration options for splitting text by tokens
*/
interface SplitByTokensOptions extends TokenEstimationOptions {
  /** Number of tokens to overlap between consecutive chunks (default: 0) */
  overlap?: number;
}
//#endregion
//#region src/index.d.ts
/**
* Checks if a text string is within a specified token limit
*/
declare function isWithinTokenLimit(text: string, tokenLimit: number, options?: TokenEstimationOptions): boolean;
/** @deprecated Use `estimateTokenCount` instead */
declare const approximateTokenSize: typeof estimateTokenCount;
/**
* Estimates the number of tokens in a text string using heuristic rules.
*/
declare function estimateTokenCount(text?: string, options?: TokenEstimationOptions): number;
/**
* Extracts a portion of text based on token positions, similar to Array.prototype.slice().
*/
declare function sliceByTokens(text: string, start?: number, end?: number, options?: TokenEstimationOptions): string;
/**
* Splits text into chunks based on token count.
*/
declare function splitByTokens(text: string, tokensPerChunk: number, options?: SplitByTokensOptions): string[];
//#endregion
export { LanguageConfig, SplitByTokensOptions, TokenEstimationOptions, approximateTokenSize, estimateTokenCount, isWithinTokenLimit, sliceByTokens, splitByTokens };