fn main() {
    let mut buffer = itoa::Buffer::new();
    println!("{} crate vendored", buffer.format(1));
}
