/// Java classes a module writes only in types (rules/uses.flix counts the imports used): `StringBuilder` only as a
/// result type, `File` only as a parameter type.
mod JavaTypes {
    import java.io.File
    import java.lang.StringBuilder

    pub def builder(): StringBuilder \ IO = JavaMake.builder()

    pub def ignore(_f: File): Int32 = 1
}

mod JavaMake {
    import java.lang.StringBuilder

    pub def builder(): StringBuilder \ IO = new StringBuilder()
}
