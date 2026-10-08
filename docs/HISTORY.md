# History

The warehouse backend was first published as the source-only demo release
`v0.2.2-demo` (September 2026): a fixed-OTP, loopback-only demonstration with
Android-first device evidence. Between late September and 8 October 2026 the
operator installation path (`setup.sh --operator`, Cloudflare Tunnel ingress,
MSG91 OTP, the staff policy, backup format v4, in-place restore and signing-key
rotation) was built and exercised on a single pilot VM, ending with an
eight-hour soak and a second-pass review. The public repository was then
re-created with a fresh squashed history. The complete pre-squash history,
including the immutable `v0.2.2-demo` tag and every dated acceptance document,
lives in the private archive repository
`abhiguru/supabase-warehouse-template-archive`; the pilot's fixture harness,
soak tooling, VM evidence and the dated narrative trimmed from the public docs
live in the private `abhiguru/warehouse-pilot-tooling` repository. Neither is
needed to install or develop this template, and nothing recorded there
validates a new installation.
