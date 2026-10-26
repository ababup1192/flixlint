package refactor

import "strings"

// Host は flixlint の道具を組み込む側（flix_game_engine の bin/fge など）が差し込む口。どれも nil なら使わない
// （flix-search・flix-refactor を単独で流す時）。組み込む側は init で SetHost を 1 回呼ぶ。
//
// WhyNot: 組み込む側のパッケージを import しない。flixlint は Flix のプロジェクトならどれにでも使う道具で、
// ゲームエンジンの決まり（engine の置き場・文書の名指しの規約）はエンジンの側の物。
type HostHooks struct {
	// EngineDir は root から見た engine の根（marker のファイルを持つ所。見つからなければ ""）。
	// FindFlixJar（engine の bin/flix.jar）と、remove-dead・make-private が名前を探す engine の Makefile・mk/ に使う。
	EngineDir func(root, marker string) string
	// DocMentions は文書が名指す def の名前（Key は索引で引く形の名前の終わり・File は根からの相対・Line は 1 から）。
	// rulesRoot は名指しの決まりを読んだ所（言うため）。ok=false は文書を見ていない。remove-dead が消した後の next に使う
	// （文書の名指しの決まりは組み込む側の物なので）。
	DocMentions func(root, engine string) (docs []DocMention, rulesRoot string, ok bool)
	// DocCheck は文書の名指しを確かめるコマンド（例 "bin/fge doc-refs"。後ろに文書のファイルを並べる）。
	// 空なら next にコマンドを書かず、直す文書だけを言う。
	DocCheck string
	// Command は答えの next に書く、この道具の呼び方（既定 flix-refactor。bin/fge から呼ぶなら "bin/fge refactor"）。
	Command string
}

// DocMention は文書が名指す名前 1 つ。
type DocMention struct {
	Key, File string
	Line      int
}

// Host は組み込む側の口（SetHost で替える）。
var Host HostHooks

// SetHost は組み込む側の口を替える。
func SetHost(h HostHooks) { Host = h }

func hostEngineDir(root, marker string) string {
	if Host.EngineDir == nil {
		return ""
	}
	return Host.EngineDir(root, marker)
}

// selfCommand は答えに書くこの道具の呼び方。
func selfCommand() string {
	if Host.Command != "" {
		return Host.Command
	}
	return "flix-refactor"
}

// docCheckNext は文書 files を確かめる next のコマンド（Host.DocCheck が空なら ""）。
func docCheckNext(files []string) string {
	if Host.DocCheck == "" {
		return ""
	}
	return Host.DocCheck + " " + strings.Join(files, " ")
}
