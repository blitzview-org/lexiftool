LUA5_4 ?= lua5.4
LUA5_5 ?= lua5.5
LUA_ROCKS ?= $(HOME)/.luarocks

# Rocks, installed per Lua version into $(LUA_ROCKS) with
# `luarocks --lua-version <5.4|5.5> --local install|make ...`:
#   lpcre          PCRE2 regex backend of the perl facade (perl.matches & Co.);
#                  from the lua-lpcre checkout: `luarocks --lua-version 5.4
#                  --local make rockspecs/lpcre-scm-0.rockspec` (likewise 5.5)
#   carray         mutable byte buffers (doc/api.md §4)
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
ROCKS_PATH = ./src/?.lua;./src/?/init.lua;$(LUA_ROCKS)/share/lua/$(1)/?.lua;$(LUA_ROCKS)/share/lua/$(1)/?/init.lua;;
ROCKS_CPATH = ./build/$(1)/?.so;./?.so;$(LUA_ROCKS)/lib/lua/$(1)/?.so;;

.PHONY: help sys sys5.4 sys5.5 check test test5.4 test5.5 test-locales lint verify usage bytecode bytecode5.4 bytecode5.5 test-cli test-cli-gen test-cli-perl test-cli-lua corpus-fetch test-corpus test-corpus-gen test-corpus-perl test-corpus-lua clean

# `make` with no target prints only this help (no implicit execution).
help:
	@echo "Available targets:"
	@echo "  make help           - this help"
	@echo "  make sys            - build the C module lexiftool.sys"
	@echo "  make check          - quality gate: sys + test + lint + verify"
	@echo "  make test           - unit tests (Lua 5.4 + 5.5), under a de_DE locale"
	@echo "                        (TEST_LOCALE=<name>[,<name>...] or TEST_LOCALE=C;"
	@echo "                        TEST_PERL=<perl> for the localtime comparisons, default perl)"
	@echo "  make test5.4        - unit tests, Lua 5.4 only"
	@echo "  make test5.5        - unit tests, Lua 5.5 only"
	@echo "  make test-locales   - unit tests under C, de_DE.UTF-8 and de_DE (single-byte)"
	@echo "  make lint           - luacheck src"
	@echo "  make verify         - structural parity check against vendor/exiftool"
	@echo "  make usage          - regenerate the help text from vendor/exiftool"
	@echo "  make exiftool-version - sync the port's hardcoded ExifTool version"
	@echo "                        from vendor/exiftool's \$$VERSION"
	@echo "  make bytecode       - compile changed modules to build/<ver>/bc/*.luac (5.4 + 5.5);"
	@echo "                        the launcher prefers fresh bytecode, LEXIFTOOL_BYTECODE=0 forces sources"
	@echo "  make test-cli-gen   - build the Perl reference tree (test-cli-ref/)"
	@echo "  make test-cli-perl  - Perl against its own reference (must be 100%)"
	@echo "  make test-cli-lua   - lexiftool against the reference (report)"
	@echo "  make corpus-fetch   - fetch/update the sample corpus (CORPUS, default vendor/exiftool-samples/)"
	@echo "  make test-corpus-gen  - build the Perl reference over the corpus (test-corpus-ref/)"
	@echo "  make test-corpus-perl - Perl against its own corpus reference (must be 100%)"
	@echo "  make test-corpus-lua  - lexiftool against the corpus reference (report);"
	@echo "                        make test-corpus is its alias"
	@echo "  make clean          - remove build/ (bytecode cache)"

# The port's own C module, built per Lua version into
# build/<version>/lexiftool/sys.so -- the first entry of ROCKS_CPATH:
#   lexiftool.sys     mandatory: $^O, setenv/tzset, chmod, truncate, %SIG,
#                     Term::ReadKey -- needs only the C runtime
# Lua headers: LUA_INCDIR_5.4 / LUA_INCDIR_5.5 if set, else pkg-config
# (lua5.4, lua-5.4, lua54), else the usual include directories. The module
# refuses to compile against the lua.h of another version.
# Windows (not driven by this Makefile):
#   MinGW: gcc -O2 -shared -I<lua>/include -o sys.dll src/lexiftool/sys.c <lua>/lua54.dll
#   MSVC:  cl /O2 /LD /I<lua>\include src\lexiftool\sys.c <lua>\lua54.lib /Fe:sys.dll
#   (install as lexiftool\sys.dll on package.cpath)
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
sys_targets = build/$(1)/lexiftool/sys.so

sys: sys5.4 sys5.5
sys5.4: $(call sys_targets,5.4)
sys5.5: $(call sys_targets,5.5)

build/%/lexiftool/sys.so: src/lexiftool/sys.c
	@mkdir -p $(dir $@)
	$(CC) $(call SYS_CFLAGS,$*) $(SYS_LDFLAGS) -o $@ $<


# single quality gate: C modules + functional tests + lint + structural parity
check: sys test lint verify

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

# structural parity check of the ported modules against the vendored upstream
verify: sys5.4
	env -u LUA_PATH -u LUA_PATH_5_4 -u LUA_CPATH -u LUA_CPATH_5_4 LUA_PATH="$(call ROCKS_PATH,5.4)" LUA_CPATH="$(call ROCKS_CPATH,5.4)" $(LUA5_4) tools/verify_port.lua
	$(LUA5_4) tools/verify_structure.lua
	$(LUA5_4) tools/verify_procs.lua
	$(LUA5_4) tools/verify_sprintf.lua
	$(LUA5_4) tools/verify_sort.lua
	$(LUA5_4) tools/verify_matchbool.lua
	$(LUA5_4) tools/verify_tostring.lua
	$(LUA5_4) tools/verify_ctype.lua

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
	TEST_CLI_TOOL=lexiftool TEST_CLI_EXPECT_IDENTICAL=$(TEST_CLI_EXPECT_IDENTICAL) $(TEST_CLI_RUN)

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
	TEST_CORPUS_TOOL=lexiftool TEST_CORPUS_EXPECT_IDENTICAL=$(TEST_CORPUS_EXPECT_IDENTICAL) $(TEST_CORPUS_RUN)

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
# (src/lexiftool/Exif.lua -> build/5.5/bc/lexiftool/Exif.luac). The launcher
# `lexiftool` registers a searcher that loads a module's .luac only when it
# exists and is strictly newer than the source it was built from, otherwise
# the source; LEXIFTOOL_BYTECODE=0 (launcher only) forces the sources.
# `make test`/`make check` always run from the sources.
#
# - One pattern rule per file: an edited module is recompiled on its own,
#   a deleted one has its orphaned .luac removed (the searcher would ignore it
#   anyway, as it only looks for bytecode of a source that exists).
# - Not stripped (no `luac -s`): stripped bytecode has no source name and no
#   line info, so a traceback reads "?: in main chunk", and the two modules
#   that locate something through their own chunk name (Geolocation.lua's
#   default geoDir/AltNames.dat lookup, WriteQuickTime's ConditionUUID)
#   lose it. Cost of keeping it: +0.7 ms start, ~+2 ms per first run, +18 % size.
# - The source is passed as an ABSOLUTE path, so the chunk name inside the
#   bytecode is the file a source load from this checkout would name: the
#   chunk-name lookups above work from any working directory, tracebacks name
#   the real file. A moved checkout needs a `make bytecode` (until then the
#   chunk names point at the old place; freshness is unaffected).
# - Freshness is decided on whole seconds (lfs mtime) in the launcher and
#   requires bytecode > source; a source saved in the same second as the
#   build would make them equal -- safe (the source is used) but slow until
#   the next edit, so the rule waits for the next second first. The .luac is
#   written to a temporary name and moved, so an interrupted build never
#   leaves a fresh-looking truncated file.
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

clean:
	rm -rf build

-include Makefile.standalone
