def main:
  with IO:
    library_result <- IO/DyLib/open("./build/libhvm_gemma.so", 0)
    library = Result/unwrap(library_result)
    response_bytes <- IO/DyLib/call(library, "gemma_generate", "")
    response = String/decode_utf8(Result/unwrap(response_bytes))
    * <- IO/print(response)
    * <- IO/print("\n")
    * <- IO/DyLib/close(library)
    return wrap(+0)
