// Normalized nine-tap Gaussian kernel shared by separable screen-space
// filters. Each shader supplies its own edge policy and sampled channels.
const float GAUSSIAN_WEIGHTS[5] = float[5](
    0.2270270,
    0.1945946,
    0.1216216,
    0.0540541,
    0.0162162
);
