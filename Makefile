.PHONY: test test-go regen-testdata test-resolved test-resident shim clean release ast-kinds

# test/fixture と examples に flixlint を掛けて、報告を test/expected*.txt と突き合わせる。
# 型検査もここで一緒に済む: 規則のエンジン（src/Flixlint*.flix）は生成物の Names.flix が揃って初めて
# コンパイルできるので、fixture を 1 回通す事がエンジンの型検査そのものになる。
test:
	test/run.sh

# 名前解決の直後の AST（Java の instance method の呼び出しが見えない代わりに数倍速い）でも同じ報告になる事。
test-resolved:
	FLIXLINT_STAGE=resolved test/run.sh

# 同じ報告が常駐の server（bin/flixlint --resident）を通っても出る事。2 回目からは増分の compile になる。
# 型の別名が変わった後の常駐の check も素の flix check と同じ答えになる事（check-alias.sh）。
test-resident:
	FLIXLINT_RESIDENT=1 test/run.sh
	FLIXLINT_RESIDENT=1 FLIXLINT_STAGE=resolved test/run.sh
	test/check-alias.sh build/check-alias

# Scala の shim を build/flixlint-shim.jar に組む（bin/flixlint も初回と shim/*.scala の変更時に同じ事をする）。
# 出来る jar は flixlint のクラスだけで、コンパイラの内部 AST に対して組むので Flix のバージョンに紐づく。
shim:
	devbox run -- scala-cli --power package shim --jar "$$(bin/flix-jar)" --library -o build/flixlint-shim.jar -f

# 汎用の AST の語彙（Kind・Slot・Attr）をコンパイラの jar から作る: schema/ast_schema.tsv・src/Flixlint/AstKinds.flix・shim/AstNames.scala。
# Flix の版を上げた時に流し、出来た 3 つはリポに置く（実行のたびには作らない）。
ast-kinds: shim
	java -cp "$$(bin/flix-jar):build/flixlint-shim.jar" flixlint.AstSchema --schema schema/ast_schema.tsv --kinds src/Flixlint/AstKinds.flix --names shim/AstNames.scala
	$(MAKE) --no-print-directory shim

# go/ の flix-search・flix-refactor と、その下の refactor・checkres のテスト。
test-go:
	cd go && go vet ./... && go test ./...

# go/refactor の testdata の索引（go/refactor/testdata/regen.json の一覧）を bin/flixlint で作り直す（typed を含み重い）。
regen-testdata:
	cd go && go test ./refactor -count=1 -run TestRegenIndex -regen-index "$(abspath bin/flixlint)"

clean:
	rm -rf build shim/.scala-build

# GitHub の release に shim の jar を付ける。利用側は scala-cli 無しで
# FLIXLINT_SHIM=... / --shim ... に渡せる（README の "Installing"）。
# WhyNot: .fpkg は作らない。flix build-pkg は src/**/*.flix しか詰めず、bin/ も shim も入らない（flix.toml の WhyNot）。
VERSION    = $(shell sed -n 's/^version *= *"\(.*\)"/\1/p' flix.toml)
FLIX_VER   = $(shell sed -n 's/^flix *= *"\(.*\)"/\1/p' flix.toml)

release: shim
	cp build/flixlint-shim.jar build/flixlint-shim-$(FLIX_VER).jar
	gh release create v$(VERSION) build/flixlint-shim-$(FLIX_VER).jar \
	  --title "v$(VERSION)" --notes "flixlint $(VERSION) (Flix $(FLIX_VER))"
