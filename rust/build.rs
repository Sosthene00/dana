fn main() {
    // Force 16KB-aligned LOAD segments for Android 15+ (API 35+) devices and
    // emulators that use 16KB pages. Without this, bionic maps segments at the
    // wrong virtual offset and mis-reads the PT_DYNAMIC section, producing the
    // "empty/missing DT_HASH/DT_GNU_HASH" dlopen error at runtime.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("android") {
        println!("cargo:rustc-link-arg=-Wl,-z,max-page-size=16384");
    }
}
