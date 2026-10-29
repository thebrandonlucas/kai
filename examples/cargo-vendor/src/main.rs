fn main() {
    let mut integer = itoa::Buffer::new();
    let mut float = ryu::Buffer::new();
    let (crates, git) = (integer.format(2), float.format(1.0));
    println!("{crates} crates vendored, {git} from git");
}
