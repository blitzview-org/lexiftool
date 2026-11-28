LUA5_4 ?= lua5.4
LUA5_5 ?= lua5.5
LUA_ROCKS ?= $(HOME)/.luarocks

# Rocks, installed per Lua version into $(LUA_ROCKS) with
# `luarocks --lua-version <5.4|5.5> --local install|make ...`:
#   lpcre          PCRE2 regex backend of the perl facade (perl.matches & Co.);
#                  `luarocks --lua-version 5.4 --local install lpcre`
#                  (likewise 5.5)
#   carray         mutable byte buffers (doc/perl-facade.md §4)
#   luafilesystem  perl.stat/readdir (lfs)
#   digest         Digest::MD5, Digest::SHA (>= 0.0.1)
#   compress.zlib  Compress::Zlib, IO::Compress::RawDeflate,
#                  IO::Uncompress::RawInflate/Gunzip (needs zlib)
#   compress.brotli IO::Uncompress::Brotli/IO::Compress::Brotli (needs
#                  libbrotlidec/libbrotlienc; BROTLIDEC_DIR=... BROTLIENC_DIR=...
#                  where luarocks does not find them)
#   compress.lzma  Compress::Raw::Lzma (needs liblzma; LZMA_DIR=...)
#   compress.bzip2 IO::Uncompress::Bunzip2 (needs libbz2; BZIP2_DIR=...)
#   cipher.aes     AES de/encryption of PDF documents (AES.lua)
#   cipher.rc4     RC4 de/encryption of PDF documents (PDF.lua)
# All of them are required.
# The module paths of the Makefile's targets (as LUA_PATH/LUA_CPATH, with
# the versioned LUA_PATH_5_x/LUA_CPATH_5_x unset; the trailing ;; is Lua's
# default path): the checkout's src/ and build/<ver>/, then $(LUA_ROCKS).
# Absolute, so a child process in another working directory (the test-cli
# cases run in work/) finds the same modules. activate.sh sets up the same
# order for an interactive shell; the launcher sets none (README.md
# "Starting lexiftool").
ROCKS_PATH = $(CURDIR)/src/?.lua;$(CURDIR)/src/?/init.lua;$(LUA_ROCKS)/share/lua/$(1)/?.lua;$(LUA_ROCKS)/share/lua/$(1)/?/init.lua;;
ROCKS_CPATH = $(CURDIR)/build/$(1)/?.so;./?.so;$(LUA_ROCKS)/lib/lua/$(1)/?.so;;

.PHONY: help bench sys sys5.4 sys5.5 capi-test capi-test-sideeffects capi-test-tsan capi-linux capi-install capi-shared install capi-test-tsan-embedded capi-macos capi-windows capi-test-wine capi-package-linux capi-package-macos capi-package-windows capi-test-package check test test5.4 test5.5 test-locales lint usage bytecode bytecode5.4 bytecode5.5 test-cli test-cli-gen test-cli-perl test-cli-lua corpus-fetch test-corpus test-corpus-gen test-corpus-perl test-corpus-lua clean rockspec-modules

# `make` with no target prints only this help (no implicit execution).
help:
	@echo "Available targets:"
	@echo "  make help           - this help"
	@echo "  make sys            - build the C modules lexiftool.sys and lexiftool.util"
	@echo "  make check          - quality gate: sys + test + lint + rockspec-modules"
	@echo "  make rockspec-modules - regenerate the Lua module list in rockspecs/*.rockspec"
	@echo "                        from the tree (rockspecs/update_modules.lua)"
	@echo "  make test           - unit tests (Lua 5.4 + 5.5), under a de_DE locale"
	@echo "                        (TEST_LOCALE=<name>[,<name>...] or TEST_LOCALE=C;"
	@echo "                        TEST_PERL=<perl> for the localtime comparisons, default perl)"
	@echo "  make test5.4        - unit tests, Lua 5.4 only"
	@echo "  make test5.5        - unit tests, Lua 5.5 only"
	@echo "  make test-locales   - unit tests under C, de_DE.UTF-8 and de_DE (single-byte)"
	@echo "  make lint           - luacheck src"
	@echo "  make usage          - regenerate the help text from vendor/exiftool"
	@echo "  make exiftool-version - sync the port's hardcoded ExifTool version"
	@echo "                        from vendor/exiftool's \$$VERSION"
	@echo "  make bytecode       - compile changed modules to build/<ver>/bc/*.luac (5.4 + 5.5);"
	@echo "                        test-cli-lua and test-corpus-lua run lexiftool from them"
	@echo "  make test-cli-gen   - build the Perl reference tree (test-cli-ref/)"
	@echo "  make test-cli-perl  - Perl against its own reference (must be 100%)"
	@echo "  make test-cli-lua   - lexiftool against the reference (report)"
	@echo "  make corpus-fetch   - fetch/update the sample corpus (CORPUS, default vendor/exiftool-samples/)"
	@echo "  make test-corpus-gen  - build the Perl reference over the corpus (test-corpus-ref/)"
	@echo "  make test-corpus-perl - Perl against its own corpus reference (must be 100%)"
	@echo "  make test-corpus-lua  - lexiftool against the corpus reference (report);"
	@echo "                        make test-corpus is its alias"
	@echo "  make capi-test      - C API (capi/): rock build against the system's Lua 5.5"
	@echo "                        (plus ASan), its tests, image_info vs Perl's Image::ExifTool"
	@echo "                        (Linux; macOS/Windows: capi/build-macos.sh, build-windows.sh;"
	@echo "                        perl: TEST_CLI_PERL)"
	@echo "  make capi-test-sideeffects - C API: the host process's state before/after"
	@echo "                        sessions, ASan/LSan (valgrind where it runs)"
	@echo "  make capi-test-tsan - C API: threads under ThreadSanitizer (Lua, rocks"
	@echo "                        and sys.so instrumented; TSAN_THREADS, TSAN_SHARE)"
	@echo "  make capi-linux     - C API, embedded (podman): liblexiftool.a, liblexiftool.so.3,"
	@echo "                        lexiftool.pc and the test programs in capi/build/embedded/;"
	@echo "                        capi-test and capi-test-sideeffects then cover them too"
	@echo "  make capi-install   - install the embedded C API (PREFIX, default /usr/local; DESTDIR)"
	@echo "  make capi-shared    - C API as a shared library against the system's Lua (LUA_VERSION,"
	@echo "                        default 5.5): build/<ver>/capi/liblexiftool.so.N and lexiftool.pc"
	@echo "  make install        - system-wide install of the command-line tool, the Lua modules,"
	@echo "                        the C modules and the shared C API into DESTDIR/PREFIX (default"
	@echo "                        /usr/local; LIBDIR, LUA_VERSION, LUA_BIN); the rocks come from the system"
	@echo "                        (or LUA_ROCKS_TREE); the modules as bytecode (INSTALL_BYTECODE=0: sources);"
	@echo "                        the launcher runs as LUA_BIN -E with these paths baked in"
	@echo "  make capi-test-tsan-embedded - C API, embedded build under ThreadSanitizer (podman)"
	@echo "  make capi-macos     - C API, embedded, macOS universal (podman): liblexiftool.a,"
	@echo "                        liblexiftool.3.dylib, lexiftool.pc, test programs in"
	@echo "                        capi/build/macos/ (they run on a Mac: build-macos.sh test)"
	@echo "  make capi-windows   - C API, embedded, Windows x64 (podman, mingw-w64): lexiftool.dll,"
	@echo "                        import libraries (MinGW, MSVC), liblexiftool.a, test programs"
	@echo "                        in capi/build/windows/"
	@echo "  make capi-test-wine - the Windows test programs of capi-windows under wine"
	@echo "  make capi-package-linux / capi-package-macos / capi-package-windows - the release"
	@echo "                        zip of the embedded C API (capi/build/dist/, podman)"
	@echo "  make capi-test-package - test_capi and example against the Linux zip (host cc)"
	@echo "  make bench          - performance comparison with the Perl original (hyperfine, jq,"
	@echo "                        GNU time): build/bench/README.md, benchmark.svg, results.json;"
	@echo "                        BENCH_LEXIFTOOL (default dist-linux/lexiftool), BENCH_RUNS"
	@echo "  make clean          - remove build/ (bytecode cache)"

# The port's own C modules, built per Lua version into
# build/<version>/lexiftool/{sys,util}.so -- the first entry of ROCKS_CPATH:
#   lexiftool.sys     mandatory: $^O, setenv/tzset, chmod, truncate, %SIG,
#                     Term::ReadKey -- needs only the C runtime
#   lexiftool.util    mandatory: native helpers too slow in Lua (base64decode)
#                     on strings and carrays -- needs only the C runtime
#                     (src/lexiftool/carray_capi.h is lua-carray's header)
# Lua headers: LUA_INCDIR_5.4 / LUA_INCDIR_5.5 if set, else pkg-config
# (lua5.4, lua-5.4, lua54), else the usual include directories. The module
# refuses to compile against the lua.h of another version.
# Windows (not driven by this Makefile):
#   MinGW: gcc -O2 -shared -I<lua>/include -o sys.dll src/lexiftool/sys.c <lua>/lua54.dll
#   MSVC:  cl /O2 /LD /I<lua>\include src\lexiftool\sys.c <lua>\lua54.lib /Fe:sys.dll
#   (install as lexiftool\sys.dll on package.cpath; util.c the same way)
lua_cflags = $(if $(LUA_INCDIR_$(1)),-I$(LUA_INCDIR_$(1)),$(shell \
    pkg-config --cflags lua$(1) 2>/dev/null || pkg-config --cflags lua-$(1) 2>/dev/null || \
    pkg-config --cflags lua$(subst .,,$(1)) 2>/dev/null || \
    for d in /usr/include/lua$(1) /usr/local/include/lua$(1) /usr/local/include/lua$(subst .,,$(1)) \
             /opt/homebrew/include/lua$(1) /opt/homebrew/opt/lua/include/lua$(1); do \
        [ -f $$d/lua.h ] && echo -I$$d && break; done))
SYS_CFLAGS = -O2 -fPIC -Wall -Wextra -DLEXIFTOOL_LUA_VERSION_NUM=$(subst .,0,$(1)) $(call lua_cflags,$(1))
ifeq ($(shell uname -s 2>/dev/null),Darwin)
SYS_LDFLAGS = -bundle -undefined dynamic_lookup
else
SYS_LDFLAGS = -shared
endif
sys_targets = build/$(1)/lexiftool/sys.so build/$(1)/lexiftool/util.so

sys: sys5.4 sys5.5
sys5.4: $(call sys_targets,5.4)
sys5.5: $(call sys_targets,5.5)

build/%/lexiftool/sys.so: src/lexiftool/sys.c
	@mkdir -p $(dir $@)
	$(CC) $(call SYS_CFLAGS,$*) $(CPPFLAGS) $(CFLAGS) $(SYS_LDFLAGS) $(LDFLAGS) -o $@ $<

build/%/lexiftool/util.so: src/lexiftool/util.c src/lexiftool/carray_capi.h
	@mkdir -p $(dir $@)
	$(CC) $(call SYS_CFLAGS,$*) $(CPPFLAGS) $(CFLAGS) $(SYS_LDFLAGS) $(LDFLAGS) -o $@ $<


# Regenerates the Lua module list of every rockspecs/lexiftool-*.rockspec
# from the files actually present under src/ (rockspecs/update_modules.lua;
# the marker lines "-- BEGIN/END LUA MODULES" bound the generated block).
# Idempotent: a tree already in sync is left untouched. Needs
# luafilesystem (lfs), a dependency of lexiftool anyway, so it runs with
# the same rocks path as the test targets below.
rockspec-modules:
	env -u LUA_PATH -u LUA_PATH_5_5 -u LUA_CPATH -u LUA_CPATH_5_5 LUA_PATH="$(call ROCKS_PATH,5.5)" LUA_CPATH="$(call ROCKS_CPATH,5.5)" $(LUA5_5) rockspecs/update_modules.lua

# single quality gate: C modules + functional tests + lint + rockspec in sync
# (an added/removed/renamed module must be reflected in the rockspec; a
# diff after regenerating means it wasn't and fails the gate).
check: sys test lint rockspec-modules
	git diff --exit-code -- rockspecs/*.rockspec

test: test5.4 test5.5

# The unit tests run under a locale with a decimal comma and a collation of
# its own, so formatting or sorting past the perl facade fails (src/runtests.lua
# picks the first of de_DE.UTF-8, de_DE.utf8, de-DE, German_Germany.1252 the
# C library accepts, else warns and runs under "C"). TEST_LOCALE overrides
# the candidate list; TEST_LOCALE=C turns it off. Handed over as the test-only
# global LEXIFTOOL_TEST_LOCALE, which the library never reads.
# TEST_LOCALE_REQUIRED=1 (CI) makes a missing locale an error instead.
TEST_LOCALE ?=
TEST_LOCALE_REQUIRED ?=
# TEST_PERL names the Perl whose localtime/gmtime the facade's are compared
# with (src/test/test_perl_facade.lua; default: perl on the PATH, skipped if
# there is none; once set, a Perl that does not run fails the test). Handed
# over as the test-only global LEXIFTOOL_TEST_PERL.
TEST_PERL ?=
TEST_LOCALE_ARG = $(if $(TEST_LOCALE),-e "LEXIFTOOL_TEST_LOCALE='$(TEST_LOCALE)'") \
    $(if $(TEST_LOCALE_REQUIRED),-e "LEXIFTOOL_TEST_LOCALE_REQUIRED='$(TEST_LOCALE_REQUIRED)'") \
    $(if $(TEST_PERL),-e "LEXIFTOOL_TEST_PERL='$(TEST_PERL)'")

# The suite under each kind of locale in turn: "C", the UTF-8 one, and a
# single-byte one (glibc's de_DE is ISO-8859-1), where Lua's pattern classes
# and string.lower/upper take 0xE4 for a letter. Each must be installed
# (TEST_LOCALE_REQUIRED=1). Not part of `check`: three times the run time.
test-locales:
	$(MAKE) test TEST_LOCALE=C
	$(MAKE) test TEST_LOCALE=de_DE.UTF-8,de_DE.utf8 TEST_LOCALE_REQUIRED=1
	$(MAKE) test TEST_LOCALE=de_DE.ISO8859-1,de_DE TEST_LOCALE_REQUIRED=1

test5.4: sys5.4
	env -u LUA_PATH -u LUA_PATH_5_4 -u LUA_CPATH -u LUA_CPATH_5_4 LUA_PATH="$(call ROCKS_PATH,5.4)" LUA_CPATH="$(call ROCKS_CPATH,5.4)" $(LUA5_4) $(TEST_LOCALE_ARG) src/runtests.lua

test5.5: sys5.5
	env -u LUA_PATH -u LUA_PATH_5_5 -u LUA_CPATH -u LUA_CPATH_5_5 LUA_PATH="$(call ROCKS_PATH,5.5)" LUA_CPATH="$(call ROCKS_CPATH,5.5)" $(LUA5_5) $(TEST_LOCALE_ARG) src/runtests.lua

lint:
	luacheck src

# CLI golden test (src/test-cli/): two phases, three roles. The reference tree
# is built from the vendored Perl exiftool; `test-cli-perl` then runs the same
# Perl tool against it and must be 100% (it validates the harness and its
# determinism); `test-cli-lua` is the port's status report. Trees live next to
# this Makefile (test-cli-ref/, test-cli-out/), the scratch under build/.
# Steering: TEST_CLI_TOOL, TEST_CLI_TRACK, TEST_CLI_SCOPE, TEST_CLI_IMAGES,
# TEST_CLI_LIMIT, TEST_CLI_JOBS, TEST_CLI_LUA, TEST_CLI_ROCKS_VER,
# TEST_CLI_PERL, TEST_CLI_EXPECT_IDENTICAL (any difference is then a
# failure; the self-check always sets it, CI also for lexiftool). See
# doc/cli-tests.md.
TEST_CLI_LUA ?= $(LUA5_5)
TEST_CLI_ROCKS_VER ?= 5.5
TEST_CLI_JOBS ?=

UNAME_S := $(shell uname -s 2>/dev/null)
ifeq ($(UNAME_S),Darwin)
# The stat interposer needs a Perl that is not SIP-protected; Homebrew's is.
# (setattrlist cannot pin the change time: APFS stamps it again on the way
# out, so the interposer is the only way, as on Linux.)
TEST_CLI_PERL ?= $(firstword $(wildcard /opt/homebrew/bin/perl /usr/local/bin/perl) perl)
CTIME_SO := build/ctime_fake.so
CTIME_ENV = DYLD_INSERT_LIBRARIES="$(CURDIR)/$(CTIME_SO)"
$(CTIME_SO): tools/ctime_fake_darwin.c
	@mkdir -p $(dir $@)
	$(CC) -dynamiclib -o $@ $<
else ifeq ($(UNAME_S),Linux)
TEST_CLI_PERL ?= perl
CTIME_SO := build/ctime_fake.so
CTIME_ENV = LD_PRELOAD="$(CURDIR)/$(CTIME_SO)"
$(CTIME_SO): tools/ctime_fake.c
	@mkdir -p $(dir $@)
	$(CC) -shared -fPIC -o $@ $< -ldl
else
TEST_CLI_PERL ?= perl
CTIME_SO :=
CTIME_ENV =
endif

# Overridable so CI can point at its own rocks tree (`luarocks path`).
TEST_CLI_LUA_PATH ?= $(call ROCKS_PATH,$(TEST_CLI_ROCKS_VER))
TEST_CLI_LUA_CPATH ?= $(call ROCKS_CPATH,$(TEST_CLI_ROCKS_VER))

TEST_CLI_ENV = env -u LUA_PATH -u LUA_PATH_5_4 -u LUA_PATH_5_5 -u LUA_CPATH -u LUA_CPATH_5_4 -u LUA_CPATH_5_5 \
    LUA_PATH="$(TEST_CLI_LUA_PATH)" \
    LUA_CPATH="$(TEST_CLI_LUA_CPATH)" \
    $(CTIME_ENV) \
    PERL_HASH_SEED=0 PERL_PERTURB_KEYS=0 \
    TZ=UTC LC_ALL=C \
    TEST_CLI_PERL="$(TEST_CLI_PERL)" \
    TEST_CLI_JOBS="$(TEST_CLI_JOBS)"
TEST_CLI_RUN = $(TEST_CLI_ENV) "$(TEST_CLI_LUA)" src/test-cli/main.lua
# test-cli-lua and test-corpus-lua run lexiftool from the bytecode of `make
# bytecode`, built right before: its directory goes in front of
# TEST_CLI_LUA_PATH (Lua loads a binary chunk under any name). Overridable
# (CI on Windows: a path the native Lua understands).
TEST_CLI_BC_PATH ?= $(CURDIR)/build/$(TEST_CLI_ROCKS_VER)/bc/?.luac
TEST_CLI_BC_ENV = LUA_PATH="$(TEST_CLI_BC_PATH);$(TEST_CLI_LUA_PATH)"

# On Windows the C module comes from `luarocks make` (the rockspec knows how
# to drive MSVC); the Makefile's gcc-style sys rule is for POSIX only.
ifeq ($(OS),Windows_NT)
TEST_CLI_SYS :=
else
TEST_CLI_SYS := sys$(TEST_CLI_ROCKS_VER)
endif

test-cli-gen: $(CTIME_SO) $(TEST_CLI_SYS)
	TEST_CLI_REGEN=1 $(TEST_CLI_RUN)

test-cli-perl: $(CTIME_SO) $(TEST_CLI_SYS)
	TEST_CLI_TOOL=exiftool-perl TEST_CLI_EXPECT_IDENTICAL=1 $(TEST_CLI_RUN)

# TEST_CLI_EXPECT_IDENTICAL=1 turns the report into a gate (CI does that).
test-cli-lua: $(CTIME_SO) $(TEST_CLI_SYS)
	$(MAKE) bytecode$(TEST_CLI_ROCKS_VER)
	TEST_CLI_TOOL=lexiftool TEST_CLI_EXPECT_IDENTICAL=$(TEST_CLI_EXPECT_IDENTICAL) $(TEST_CLI_ENV) $(TEST_CLI_BC_ENV) \
	    "$(TEST_CLI_LUA)" src/test-cli/main.lua

test-cli: test-cli-lua

# Corpus run (src/test-cli/corpus.lua): the same two-phase mechanics over an
# external corpus -- by default Phil Harvey's sample images from
# https://exiftool.org/sample_images.html (one directory per manufacturer,
# metadata only), fetched by tools/fetch_corpus.sh into
# vendor/exiftool-samples/ (gitignored, never committed). Per file: -a -u -G1,
# -j -t, -v3, -X -struct, -Artist=x and -all= into a copy, each write followed
# by a readback; per manufacturer a scripted -stay_open session. By default
# every call runs as a command of one -stay_open session per manufacturer and
# tool (TEST_CORPUS_MODE=process: one process per call; the reference is per
# mode). Trees: test-corpus-ref/, test-corpus-out/ (gitignored), resumable
# after an interruption; summary.md in the out tree.
# Steering: CORPUS=<dir>, TEST_CORPUS_TRACK=read|write|stay|all,
# TEST_CORPUS_MAKES='Canon Nikon', TEST_CORPUS_SAMPLE=N (+ TEST_CORPUS_SEED),
# TEST_CORPUS_TIMEOUT=s, TEST_CORPUS_JOBS=N|auto,
# TEST_CORPUS_MODE=session|process, TEST_CORPUS_EXPECT_IDENTICAL (deviations
# beyond the known ones are then a failure; the self-check always sets it,
# CI also for lexiftool). The Lua/Perl/rocks variables are the test-cli ones.
# See doc/cli-tests.md, "Corpus run".
CORPUS ?= $(CURDIR)/vendor/exiftool-samples
TEST_CORPUS_RUN = $(TEST_CLI_ENV) TEST_CORPUS_DIR="$(CORPUS)" "$(TEST_CLI_LUA)" src/test-cli/corpus.lua

corpus-fetch:
	sh tools/fetch_corpus.sh "$(CORPUS)"

# Fetched only when the directory is missing (order-only: its mtime is not a
# reason to fetch again; `make corpus-fetch` updates explicitly).
$(CORPUS):
	sh tools/fetch_corpus.sh "$(CORPUS)"

# 1. Build (or complete) the Perl reference -- resumable, no comparison.
test-corpus-gen: $(CTIME_SO) $(TEST_CLI_SYS) | $(CORPUS)
	TEST_CORPUS_REGEN=1 $(TEST_CORPUS_RUN)

# 2. Perl against its own reference: must be 100% (any difference fails).
test-corpus-perl: $(CTIME_SO) $(TEST_CLI_SYS) | $(CORPUS)
	TEST_CORPUS_TOOL=exiftool-perl TEST_CORPUS_EXPECT_IDENTICAL=1 $(TEST_CORPUS_RUN)

# 3. lexiftool against the reference; TEST_CORPUS_EXPECT_IDENTICAL=1 turns
# the report into a gate (CI does that).
test-corpus-lua: $(CTIME_SO) $(TEST_CLI_SYS) | $(CORPUS)
	$(MAKE) bytecode$(TEST_CLI_ROCKS_VER)
	TEST_CORPUS_TOOL=lexiftool TEST_CORPUS_EXPECT_IDENTICAL=$(TEST_CORPUS_EXPECT_IDENTICAL) $(TEST_CLI_ENV) $(TEST_CLI_BC_ENV) \
	    TEST_CORPUS_DIR="$(CORPUS)" "$(TEST_CLI_LUA)" src/test-cli/corpus.lua

test-corpus: test-corpus-lua

# Regenerates src/lexiftool/usage.lua from the vendored exiftool's help output
# (see tools/usage_rules.lua). Needed after updating vendor/exiftool; requires
# perl, as the text is taken from the vendored Perl exiftool's own -h output.
usage:
	$(LUA5_5) tools/gen_usage.lua

# Copies vendor/exiftool's $VERSION into the port's own hardcoded mentions
# of it (src/lexiftool.lua, src/lexiftool/main.lua, README.md,
# doc/differences.md); a no-op if already in sync. Needed after updating
# vendor/exiftool; does not touch rockspecs/ (its own release-version
# numbering, rockspecs/setversion.lua, a separate tag-driven step) or
# usage.lua (`make usage` instead).
exiftool-version:
	$(LUA5_5) tools/set_exiftool_version.lua

# Bytecode: every module compiled per Lua version -- bytecode is
# version-bound -- into build/<version>/bc/, mirroring src/
# (src/lexiftool/Exif.lua -> build/5.5/bc/lexiftool/Exif.luac).
# test-cli-lua and test-corpus-lua build it and put build/<ver>/bc/?.luac in
# front of their LUA_PATH (TEST_CLI_BC_PATH), so the thousands of lexiftool
# runs there parse no sources; as make has just brought every .luac up to
# date, it is never stale. Nothing else uses it: `make test`/`make check`
# and activate.sh run from the sources, the bytecode of an installation is
# tools/compile_tree.lua's (`make install`), the standalone's genembed.lua's.
#
# - One pattern rule per file: an edited module is recompiled on its own,
#   a deleted one has its orphaned .luac removed (it would otherwise still
#   be found on the path).
# - Not stripped (no `luac -s`): stripped bytecode has no source name and no
#   line info, so a traceback reads "?: in main chunk", and Geolocation.lua,
#   which locates its default geoDir/AltNames.dat through its own chunk name,
#   loses it. Keeping it costs a little start-up time and size.
# - The source is passed as an ABSOLUTE path, so the chunk name inside the
#   bytecode is the file a source load from this checkout would name: the
#   chunk-name lookup above works from any working directory, tracebacks name
#   the real file. A moved checkout needs a `make bytecode` (until then the
#   chunk names point at the old place; freshness is unaffected).
# - make decides freshness on whole seconds on some systems; a source saved
#   in the same second as the build would leave the .luac looking up to
#   date, so the rule waits for the next second first. The .luac is written
#   to a temporary name and moved, so an interrupted build never leaves a
#   fresh-looking truncated file.
LUAC5_4 ?= luac5.4
LUAC5_5 ?= luac5.5
BC_SRCS := $(shell find src/lexiftool.lua src/lexiftool -name '*.lua')
bc_targets = $(patsubst src/%.lua,build/$(1)/bc/%.luac,$(BC_SRCS))
mtime_of = $$(stat -c %Y $(1) 2>/dev/null || stat -f %m $(1))
define bc_compile
	@mkdir -p $(@D)
	@[ "$(call mtime_of,$<)" -lt "$$(date +%s)" ] || sleep 1
	@echo "$(1) $<"; $(1) -o $@.tmp $(abspath $<) && mv -f $@.tmp $@
endef
define bc_prune
	@[ ! -d build/$(1)/bc ] || find build/$(1)/bc -name '*.luac*' | while read f; do \
		s=src/$${f#build/$(1)/bc/}; [ -f "$${s%.luac}.lua" ] || { echo "rm $$f"; rm -f "$$f"; }; \
	done
endef

bytecode: bytecode5.4 bytecode5.5

bytecode5.4: $(call bc_targets,5.4)
	$(call bc_prune,5.4)
bytecode5.5: $(call bc_targets,5.5)
	$(call bc_prune,5.5)

build/5.4/bc/%.luac: src/%.lua
	$(call bc_compile,$(LUAC5_4))

build/5.5/bc/%.luac: src/%.lua
	$(call bc_compile,$(LUAC5_5))

# C API (capi/, doc/capi.md) on Linux: the "rock" build of
# capi/build-linux.sh (host cc against the system's Lua 5.5 and its headers,
# the modules from the rocks; also an ASan build), test_capi under every
# build there is (ASan with LeakSanitizer; the embedded ones of capi-linux
# with test_threads and test_hostlibs as well), and lexiftool_image_info
# against Perl's Image::ExifTool (capi/example of every build vs
# capi/info_dump.pl, all of t/images, several option sets). Perl's
# FileCreateDate needs File::StatX, as for test-cli-gen.
capi-test: sys5.5
	sh capi/build-linux.sh rock
	LUA_ROCKS="$(LUA_ROCKS)" CAPI_PERL="$(TEST_CLI_PERL)" sh capi/build-linux.sh test

# Side effects on the host process (capi/test_sideeffects.c, plain and
# ASan/LSan; valgrind over test_capi where valgrind runs), rock build and
# the embedded ones of capi-linux, where built.
capi-test-sideeffects: sys5.5
	sh capi/build-linux.sh rock
	LUA_ROCKS="$(LUA_ROCKS)" sh capi/build-linux.sh sideeffects

# ThreadSanitizer (capi/test_threads.c, capi/test_capi.c): Lua, the Lua C
# modules (luarocks, from luarocks.org), lexiftool.sys, lexiftool.util and
# the C API built with -fsanitize=thread in capi/build/tsan/ (Lua and the
# rocks once, then cached); needs network access for the first build.
capi-test-tsan:
	sh capi/build-linux.sh tsan

# The embedded C API (Lua, the modules and the C libraries inside, as in the
# standalone executable), built in the Linux builder container
# (Makefile.standalone's image-linux) from its glibc 2.17 archives:
# capi/build/embedded/{include,lib,lib/pkgconfig} and the test programs,
# linked on the host against both libraries through lexiftool.pc.
capi-linux: image-linux
	sh capi/build-linux.sh embedded

# Installs it: $(DESTDIR)$(PREFIX)/include/lexiftool.h,
# lib/liblexiftool.{a,so.3,so}, lib/pkgconfig/lexiftool.pc.
PREFIX ?= /usr/local
capi-install:
	PREFIX="$(PREFIX)" DESTDIR="$(DESTDIR)" sh capi/build-linux.sh install

# The embedded build under ThreadSanitizer, in a container of the builder
# image: its dependencies (standalone/deps.sh linux-tsan, sources of
# standalone/fetch.sh, built once into capi/build/tsan-embedded/lib), the
# own objects and test_threads/test_capi with -fsanitize=thread; needs
# network access for the first build.
capi-test-tsan-embedded: image-linux
	sh capi/build-linux.sh tsan-embedded

# The embedded C API for macOS (universal x86_64 + arm64, zig cc) and
# Windows (x64, mingw-w64), built in the builder containers of the
# standalone executables (capi/build-macos.sh, capi/build-windows.sh
# embedded). The macOS programs run on a Mac only (build-macos.sh test);
# the Windows ones run here under wine (capi-test-wine; Perl comparison and
# MSVC link test on Windows itself, build-windows.sh msvc/test).
capi-macos: image-macos
	sh capi/build-macos.sh embedded

capi-windows: image-windows
	sh capi/build-windows.sh embedded

capi-test-wine:
	WINEDEBUG=-all CAPI_RUNNER=wine sh capi/build-windows.sh test

# The release zips of the embedded C API (capi/package.sh), one per
# platform, in capi/build/dist/lexiftool-capi-<platform>-<version>.zip:
# the libraries of capi-<platform>, the header, example.c, doc/capi.md and
# the licenses as in the standalone zip; packed in the builder container,
# reproducibly. capi-test-package links test_capi and example against the
# Linux zip with the host's cc and runs them (capi/test-package.sh).
capi-package-linux capi-package-macos capi-package-windows: capi-package-%: capi-%
	sh capi/package.sh $*

capi-test-package:
	sh capi/test-package.sh capi/build/dist/lexiftool-capi-linux-*.zip

# System-wide installation (`make install`): the command-line tool, the Lua
# modules (sources, as the rock installs them), lexiftool.sys and the C API
# as a shared library against the system's Lua, into $(DESTDIR)$(PREFIX) --
# the layout of a distribution package. Nothing is embedded: the rocks
# lexiftool needs (README.md "Installation") come from the system as well,
# found through Lua's default package.path/cpath. The installed launcher
# and the shared library put the installation's own module directories,
# $(PREFIX)/share/lua/<ver>/ and $(LIBDIR)/lua/<ver>/ (without DESTDIR: the
# paths at run time), and LUA_ROCKS_TREE's when set, in front of that
# default and ignore LUA_PATH/LUA_CPATH/LUA_INIT (the launcher's shebang is
# `LUA_BIN -E`, the library sets LUA_NOENV): an installed lexiftool runs the
# same whatever the environment.
# The modules are installed as bytecode of that Lua (INSTALL_BYTECODE=1, the
# default; 0 installs the sources): Lua loads a binary chunk whatever the
# file is called, and a start parses no sources -- a few hundred KB even
# for -ver, with tag tables of several MB behind it -- so the installed tool
# starts as fast as the standalone executable. tools/compile_tree.lua does
# it (run by LUA_BIN, so the bytecode is that version's) with the chunk
# names of the final installation path (Geolocation.lua finds its .dat
# through its chunk name) and the debug information kept (tracebacks,
# perl.lua's Time::Local croak).
#   INSTALL_BYTECODE  1 (default) bytecode, 0 sources
#   LUA_VERSION   the Lua installed for (5.4 or 5.5; default 5.5)
#   LUA_PC        its pkg-config name (the first of lua<ver>, lua-<ver>,
#                 lua<v><v>, lua that pkg-config knows), else the include
#                 directories of lua_cflags and -llua<ver>
#   LUA_BIN       the interpreter the installed launcher runs on (its
#                 absolute path goes in the shebang)
#   LUA_ROCKS_TREE  optional: a rock tree (e.g. for a PREFIX outside the
#                 default paths, with the rocks in a tree of its own) whose
#                 share/lua/<ver>/ and lib/lua/<ver>/ come right after the
#                 installation's own directories
#   PREFIX        default /usr/local (as for capi-install); LIBDIR, default
#                 $(PREFIX)/lib; DESTDIR for staged installs
#   PORT_VERSION  the build's identity (`git describe`, as SA_IDENTITY):
#                 baked into the launcher (_G.LEXIFTOOL_PORT_VERSION, shown
#                 by `lexiftool -ver -v`) and the library
#                 (lexiftool_version()); its numeric part is the .pc Version
# The shared library (capi-shared, build/<ver>/capi/) is capi/lexiftool.c
# alone -- the "rock" build variant of capi/build-linux.sh as a shared
# object (doc/capi.md "Build variants"): soname liblexiftool.so.<API>,
# linked against the system's liblua, exporting lexiftool_* only
# (-fvisibility=hidden; the header marks the API). CFLAGS/LDFLAGS from the
# environment are honoured (distribution build flags).
LUA_VERSION ?= 5.5
INSTALL_BYTECODE ?= 1
LUA_PC ?= $(shell for p in lua$(LUA_VERSION) lua-$(LUA_VERSION) lua$(subst .,,$(LUA_VERSION)) lua; do \
    pkg-config --exists $$p 2>/dev/null && echo $$p && break; done)
LUA_BIN ?= $(shell command -v lua$(LUA_VERSION) 2>/dev/null || \
    command -v lua$(subst .,,$(LUA_VERSION)) 2>/dev/null || command -v lua 2>/dev/null || echo lua)
LIBDIR ?= $(PREFIX)/lib
LUA_ROCKS_TREE ?=
PORT_VERSION ?= $(shell git describe --tags --always --long --dirty --match 'v*' 2>/dev/null || echo Unknown)
# the numeric version for lexiftool.pc (v13.64.0-3-gabc-dirty -> 13.64.0; 0 without a tag)
PC_VERSION = $(or $(shell echo '$(PORT_VERSION)' | sed -n 's/^v\([0-9][0-9.]*[0-9]\).*/\1/p'),0)
# ('.' for the '#' of #define: GNU make 3.81, as macOS ships it, reads a '#'
#  inside $(shell ...) as the start of a comment)
CAPI_API = $(shell sed -n 's/^.define LEXIFTOOL_API_VERSION \([0-9][0-9]*\).*/\1/p' capi/lexiftool.h)
CAPI_DIR = build/$(LUA_VERSION)/capi
CAPI_LUA_CFLAGS = $(if $(LUA_PC),$(shell pkg-config --cflags $(LUA_PC)),$(call lua_cflags,$(LUA_VERSION)))
CAPI_LUA_LIBS = $(if $(LUA_PC),$(shell pkg-config --libs $(LUA_PC)),-llua$(LUA_VERSION))

capi-shared: $(CAPI_DIR)/liblexiftool.so.$(CAPI_API) $(CAPI_DIR)/lexiftool.pc

# capi/session.lua as a C array (genheader of capi/common.sh)
$(CAPI_DIR)/session_lua.h: capi/session.lua capi/common.sh
	@mkdir -p $(dir $@)
	CAPI=capi PROJECT=. sh -c '. capi/common.sh && genheader "$(LUA_BIN)" "$@"'

# The installation paths baked into the library (capi/lexiftool.c,
# LEXIFTOOL_PREFIX & Co.); paths.stamp changes only when they do, so a
# different PREFIX rebuilds it.
CAPI_PATH_DEFS = -DLEXIFTOOL_PREFIX='"$(PREFIX)"' -DLEXIFTOOL_LIBDIR='"$(LIBDIR)"' \
    $(if $(LUA_ROCKS_TREE),-DLEXIFTOOL_ROCKS_TREE='"$(LUA_ROCKS_TREE)"')
.PHONY: FORCE
FORCE:
$(CAPI_DIR)/paths.stamp: FORCE
	@mkdir -p $(dir $@)
	@echo '$(CAPI_PATH_DEFS)' > $@.tmp; \
	if cmp -s $@.tmp $@; then rm -f $@.tmp; else mv -f $@.tmp $@; fi

$(CAPI_DIR)/liblexiftool.so.$(CAPI_API): capi/lexiftool.c capi/lexiftool.h $(CAPI_DIR)/session_lua.h $(CAPI_DIR)/paths.stamp
	$(CC) -O2 -Wall -Wextra -fPIC -fvisibility=hidden $(CPPFLAGS) $(CFLAGS) $(CAPI_LUA_CFLAGS) -I$(CAPI_DIR) \
	    -DLEXIFTOOL_PORT_VERSION='"$(PORT_VERSION)"' $(CAPI_PATH_DEFS) \
	    -shared -Wl,-soname,liblexiftool.so.$(CAPI_API) $(LDFLAGS) -o $@ $< $(CAPI_LUA_LIBS) -lm -lpthread
	ln -sf liblexiftool.so.$(CAPI_API) $(CAPI_DIR)/liblexiftool.so

# written on every run: PREFIX, LIBDIR and the version are not inputs make
# could track
.PHONY: $(CAPI_DIR)/lexiftool.pc
$(CAPI_DIR)/lexiftool.pc:
	@mkdir -p $(dir $@)
	@{ echo 'prefix=$(PREFIX)'; echo 'libdir=$(LIBDIR)'; echo 'includedir=$${prefix}/include'; echo; \
	   echo 'Name: lexiftool'; \
	   echo 'Description: Image metadata (a Lua port of ExifTool) through a C API; Lua and modules from the system'; \
	   echo 'Version: $(PC_VERSION)'; \
	   $(if $(LUA_PC),echo 'Requires.private: $(LUA_PC)';) \
	   echo 'Cflags: -I$${includedir}'; \
	   echo 'Libs: -L$${libdir} -llexiftool'; \
	   echo 'Libs.private: $(if $(LUA_PC),,$(CAPI_LUA_LIBS) )-lm -lpthread'; } > $@
	@echo "$@ (prefix $(PREFIX), Version $(PC_VERSION))"

# The installed launcher: the shebang is `#!<LUA_BIN, absolute> -E`, and
# its marker line `-- @@INSTALL@@` becomes the build's identity (the
# checkout's launcher has none: "Unknown") and the installation's module
# paths in front of Lua's default ones (see above).
INSTALL_BIN = $(DESTDIR)$(PREFIX)/bin
INSTALL_LMOD = $(DESTDIR)$(PREFIX)/share/lua/$(LUA_VERSION)
INSTALL_CMOD = $(DESTDIR)$(LIBDIR)/lua/$(LUA_VERSION)
INSTALL_LIB = $(DESTDIR)$(LIBDIR)
INSTALL_INC = $(DESTDIR)$(PREFIX)/include

install: sys$(LUA_VERSION) capi-shared
	@mkdir -p "$(INSTALL_BIN)" "$(INSTALL_LMOD)/lexiftool" "$(INSTALL_CMOD)/lexiftool" \
	    "$(INSTALL_LIB)/pkgconfig" "$(INSTALL_INC)"
	@lua=$$(command -v "$(LUA_BIN)") && case "$$lua" in /*) ;; *) false ;; esac || \
	    { echo "make install: LUA_BIN=$(LUA_BIN) is not an interpreter with an absolute path" >&2; exit 1; }; \
	v="$(LUA_VERSION)"; tree="$(LUA_ROCKS_TREE)"; \
	lpath="$(PREFIX)/share/lua/$$v/?.lua;$(PREFIX)/share/lua/$$v/?/init.lua;"; \
	cpath="$(LIBDIR)/lua/$$v/?.so;"; \
	if [ -n "$$tree" ]; then \
	    lpath="$$lpath$$tree/share/lua/$$v/?.lua;$$tree/share/lua/$$v/?/init.lua;"; \
	    cpath="$$cpath$$tree/lib/lua/$$v/?.so;"; \
	fi; \
	echo "$(INSTALL_BIN)/lexiftool: #!$$lua -E"; \
	awk -v lua="$$lua" -v ver="$(PORT_VERSION)" -v lpath="$$lpath" -v cpath="$$cpath" ' \
	    function q(s) { return "[==[" s "]==]" } \
	    NR == 1 && /^#!/ { print "#!" lua " -E"; next } \
	    /^-- @@INSTALL@@/ && !done { \
	        print "-- set by `make install`: the build'"'"'s identity (CONTRIBUTING.md \"Configuration\")"; \
	        print "-- and this installation'"'"'s module paths, in front of Lua'"'"'s default ones"; \
	        print "_G.LEXIFTOOL_PORT_VERSION = " q(ver); \
	        print "package.path = " q(lpath) " .. package.path"; \
	        print "package.cpath = " q(cpath) " .. package.cpath"; done = 1; next } \
	    { print } \
	    END { if (!done) { print "make install: no -- @@INSTALL@@ line in bin/lexiftool" > "/dev/stderr"; exit 1 } }' \
	    bin/lexiftool > "$(INSTALL_BIN)/lexiftool"
	chmod 755 "$(INSTALL_BIN)/lexiftool"
ifeq ($(INSTALL_BYTECODE),0)
	cd src && find lexiftool.lua lexiftool -type f \( -name '*.lua' -o -name '*.dat' \) | while read -r f; do \
	    mkdir -p "$(INSTALL_LMOD)/$$(dirname "$$f")" && install -m 644 "$$f" "$(INSTALL_LMOD)/$$f" || exit 1; done
else
	"$(LUA_BIN)" tools/compile_tree.lua src "$(INSTALL_LMOD)" "$(PREFIX)/share/lua/$(LUA_VERSION)"
endif
	install -m 755 build/$(LUA_VERSION)/lexiftool/sys.so "$(INSTALL_CMOD)/lexiftool/sys.so"
	install -m 755 build/$(LUA_VERSION)/lexiftool/util.so "$(INSTALL_CMOD)/lexiftool/util.so"
	install -m 755 $(CAPI_DIR)/liblexiftool.so.$(CAPI_API) "$(INSTALL_LIB)/liblexiftool.so.$(CAPI_API)"
	ln -sf liblexiftool.so.$(CAPI_API) "$(INSTALL_LIB)/liblexiftool.so"
	install -m 644 capi/lexiftool.h "$(INSTALL_INC)/lexiftool.h"
	install -m 644 $(CAPI_DIR)/lexiftool.pc "$(INSTALL_LIB)/pkgconfig/lexiftool.pc"
	@echo "installed lexiftool $(PORT_VERSION) for Lua $(LUA_VERSION) into $(DESTDIR)$(PREFIX)"

# Performance comparison with the Perl original (tools/bench_cli.sh,
# doc/benchmark.md): the vendored Perl exiftool against BENCH_LEXIFTOOL, by
# default the Linux standalone executable (`make linux` first), BENCH_RUNS
# timed runs per case and tool. CI runs it on every push (benchmark.yml).
BENCH_LEXIFTOOL ?= dist-linux/lexiftool
BENCH_RUNS ?= 20
BENCH_PERL ?= perl -Ivendor/exiftool/lib vendor/exiftool/exiftool
bench:
	tools/bench_cli.sh build/bench '$(BENCH_PERL)' '$(BENCH_LEXIFTOOL)' $(BENCH_RUNS)

clean:
	rm -rf build

-include Makefile.standalone
