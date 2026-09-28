// Snowball stemmers (https://snowballstem.org, BSD 3-clause; see COPYING), vendored from
// libstemmer_c 3.0.1: the runtime and the UTF-8 Greek and Russian stemmers only. Moria stems
// query words in scripts where one language dominates; Latin script is stemmed by the index's
// Porter tokenizer.
#include "../runtime/api.h"
#include "../src_c/stem_UTF_8_greek.h"
#include "../src_c/stem_UTF_8_russian.h"
