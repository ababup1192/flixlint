.PHONY: test test-resolved shim clean release

# test/fixture と examples に flixlint を掛けて、報告を test/expected*.txt と突き合わせる。
# 型検査もここで一緒に済む: 規則のエンジン（src/Flixlint*.flix）は生成物の Names.flix が揃って初めて
# コンパイルできるので、fixture を 1 回通す事がエンジンの型検査そのものになる。
test:
	test/run.sh

# 名前解決の直後の AST（Java の instance method の呼び出しが見えない代わりに数倍速い）でも同じ報告になる事。
test-resolved:
	FLIXLINT_STAGE=resolved test/run.sh

# Scala の shim を build/flixlint-shim.jar に組む（bin/flixlint も初回と shim/*.scala の変更時に同じ事をする）。
# 出来る jar は flixlint のクラスだけで、コンパイラの内部 AST に対して組むので Flix のバージョンに紐づく。
shim:
	devbox run -- scala-cli --power package shim --jar "$$(bin/flix-jar)" --library -o build/flixlint-shim.jar -f

clean:
	rm -rf build shim/.scala-build

# GitHub の release に shim の jar を付ける。利用側は scala-cli 無しで
# FLIXLINT_SHIM=... / --shim ... に渡せる（README「shim の届け方」）。
# WhyNot: .fpkg は作らない。flix build-pkg は src/**/*.flix しか詰めず、bin/ も shim も入らない（flix.toml の WhyNot）。
VERSION    = $(shell sed -n 's/^version *= *"\(.*\)"/\1/p' flix.toml)
FLIX_VER   = $(shell sed -n 's/^flix *= *"\(.*\)"/\1/p' flix.toml)

release: shim
	cp build/flixlint-shim.jar build/flixlint-shim-$(FLIX_VER).jar
	gh release create v$(VERSION) build/flixlint-shim-$(FLIX_VER).jar \
	  --title "v$(VERSION)" --notes "flixlint $(VERSION) (Flix $(FLIX_VER))"
