// C interface of the Harper grammar checker wrapper (rust/harper-ffi). Used as a Swift bridging header.
// Strings are UTF-8 JSON. Offsets count Unicode scalars. Free returned strings with harper_free.
#ifndef HARPER_FFI_H
#define HARPER_FFI_H

void harper_set_dialect(int dialect);              // 0 American, 1 British, 2 Canadian, 3 Australian, 4 Indian
void harper_set_words(const char *json_array);     // words that are never misspellings
char *harper_lint(const char *text, int isolate_english);
char *harper_synonyms(const char *word);
void harper_free(char *ptr);

#endif
