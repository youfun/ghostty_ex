# Windows NIF compatibility headers

These headers are vendored from [Zigler 0.16.0](https://github.com/E-xyza/zigler/tree/0.16.0/priv/erl_nif_win), whose Hex package omits this directory. They originate from Erlang/OTP and retain Ericsson AB's copyright and Apache-2.0 notices. See [LICENSE](LICENSE) for the license text.

- `erl_nif_api_funcs_win.h` is unchanged from Zigler 0.16.0 (SHA256 `dd43c4dd22fb6a158af420754fb8cb6c255e069d87e1c294d09f3e9f897345ef`).
- `erl_nif_win.h` adds `<string.h>` to declare `memcpy` used by `ERL_NIF_INIT_BODY`; the change is marked in the file. Its upstream SHA256 before this change is `ee0162831e553eb559c1b884ce461b100a0ff792c401a66be9e6b5ad00883a77`.

Other included Erlang headers (`erl_drv_nif.h` and `erl_nif_api_funcs.h`) come from the installed OTP include directory. The callback table layout follows that installed OTP header.

`mix ghostty.setup` installs these files into Zigler's `priv/erl_nif_win` on Windows. The compile alias also fills in missing headers for dependency builds.
