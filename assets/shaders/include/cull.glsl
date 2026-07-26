// Shared between the passes that write the visible list and the pass that
// reads it. The value has to agree across all three, and it did not have to
// before: each pass declared its own copy, so a change to one was a silent
// disagreement rather than a compile error.

// Written into a slot whose instance failed the view test.
const uint CULLED = 0xFFFFFFFFu;
