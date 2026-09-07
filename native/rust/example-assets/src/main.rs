mod assets;
fn main() -> anyhow::Result<()> {
    let mut args = std::env::args().skip(1);
    let name = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("use nupp task fetch sponza|bistro"))?;
    anyhow::ensure!(args.next().is_none(), "unexpected asset importer argument");
    assets::fetch(&std::env::current_dir()?, &name)
}
