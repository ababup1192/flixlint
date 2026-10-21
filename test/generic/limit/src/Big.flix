// A record alias of 40 fields used in 100 signatures: written out at every use it would be 100 copies of the record,
// as a shared type it is one row. test/run.sh walks it with the default limit and with a limit it must break.
mod Big {
    pub type alias State = {
        f1 = Int32,
        f2 = Int32,
        f3 = Int32,
        f4 = Int32,
        f5 = Int32,
        f6 = Int32,
        f7 = Int32,
        f8 = Int32,
        f9 = Int32,
        f10 = Int32,
        f11 = Int32,
        f12 = Int32,
        f13 = Int32,
        f14 = Int32,
        f15 = Int32,
        f16 = Int32,
        f17 = Int32,
        f18 = Int32,
        f19 = Int32,
        f20 = Int32,
        f21 = Int32,
        f22 = Int32,
        f23 = Int32,
        f24 = Int32,
        f25 = Int32,
        f26 = Int32,
        f27 = Int32,
        f28 = Int32,
        f29 = Int32,
        f30 = Int32,
        f31 = Int32,
        f32 = Int32,
        f33 = Int32,
        f34 = Int32,
        f35 = Int32,
        f36 = Int32,
        f37 = Int32,
        f38 = Int32,
        f39 = Int32,
        f40 = Int32 
    }

    pub def start(): State = {
        f1 = 1,
        f2 = 2,
        f3 = 3,
        f4 = 4,
        f5 = 5,
        f6 = 6,
        f7 = 7,
        f8 = 8,
        f9 = 9,
        f10 = 10,
        f11 = 11,
        f12 = 12,
        f13 = 13,
        f14 = 14,
        f15 = 15,
        f16 = 16,
        f17 = 17,
        f18 = 18,
        f19 = 19,
        f20 = 20,
        f21 = 21,
        f22 = 22,
        f23 = 23,
        f24 = 24,
        f25 = 25,
        f26 = 26,
        f27 = 27,
        f28 = 28,
        f29 = 29,
        f30 = 30,
        f31 = 31,
        f32 = 32,
        f33 = 33,
        f34 = 34,
        f35 = 35,
        f36 = 36,
        f37 = 37,
        f38 = 38,
        f39 = 39,
        f40 = 40
    }

    pub def step1(s: State): State = { f1 = s#f1 + 1 | s }

    pub def step2(s: State): State = { f1 = s#f1 + 2 | s }

    pub def step3(s: State): State = { f1 = s#f1 + 3 | s }

    pub def step4(s: State): State = { f1 = s#f1 + 4 | s }

    pub def step5(s: State): State = { f1 = s#f1 + 5 | s }

    pub def step6(s: State): State = { f1 = s#f1 + 6 | s }

    pub def step7(s: State): State = { f1 = s#f1 + 7 | s }

    pub def step8(s: State): State = { f1 = s#f1 + 8 | s }

    pub def step9(s: State): State = { f1 = s#f1 + 9 | s }

    pub def step10(s: State): State = { f1 = s#f1 + 10 | s }

    pub def step11(s: State): State = { f1 = s#f1 + 11 | s }

    pub def step12(s: State): State = { f1 = s#f1 + 12 | s }

    pub def step13(s: State): State = { f1 = s#f1 + 13 | s }

    pub def step14(s: State): State = { f1 = s#f1 + 14 | s }

    pub def step15(s: State): State = { f1 = s#f1 + 15 | s }

    pub def step16(s: State): State = { f1 = s#f1 + 16 | s }

    pub def step17(s: State): State = { f1 = s#f1 + 17 | s }

    pub def step18(s: State): State = { f1 = s#f1 + 18 | s }

    pub def step19(s: State): State = { f1 = s#f1 + 19 | s }

    pub def step20(s: State): State = { f1 = s#f1 + 20 | s }

    pub def step21(s: State): State = { f1 = s#f1 + 21 | s }

    pub def step22(s: State): State = { f1 = s#f1 + 22 | s }

    pub def step23(s: State): State = { f1 = s#f1 + 23 | s }

    pub def step24(s: State): State = { f1 = s#f1 + 24 | s }

    pub def step25(s: State): State = { f1 = s#f1 + 25 | s }

    pub def step26(s: State): State = { f1 = s#f1 + 26 | s }

    pub def step27(s: State): State = { f1 = s#f1 + 27 | s }

    pub def step28(s: State): State = { f1 = s#f1 + 28 | s }

    pub def step29(s: State): State = { f1 = s#f1 + 29 | s }

    pub def step30(s: State): State = { f1 = s#f1 + 30 | s }

    pub def step31(s: State): State = { f1 = s#f1 + 31 | s }

    pub def step32(s: State): State = { f1 = s#f1 + 32 | s }

    pub def step33(s: State): State = { f1 = s#f1 + 33 | s }

    pub def step34(s: State): State = { f1 = s#f1 + 34 | s }

    pub def step35(s: State): State = { f1 = s#f1 + 35 | s }

    pub def step36(s: State): State = { f1 = s#f1 + 36 | s }

    pub def step37(s: State): State = { f1 = s#f1 + 37 | s }

    pub def step38(s: State): State = { f1 = s#f1 + 38 | s }

    pub def step39(s: State): State = { f1 = s#f1 + 39 | s }

    pub def step40(s: State): State = { f1 = s#f1 + 40 | s }

    pub def step41(s: State): State = { f1 = s#f1 + 41 | s }

    pub def step42(s: State): State = { f1 = s#f1 + 42 | s }

    pub def step43(s: State): State = { f1 = s#f1 + 43 | s }

    pub def step44(s: State): State = { f1 = s#f1 + 44 | s }

    pub def step45(s: State): State = { f1 = s#f1 + 45 | s }

    pub def step46(s: State): State = { f1 = s#f1 + 46 | s }

    pub def step47(s: State): State = { f1 = s#f1 + 47 | s }

    pub def step48(s: State): State = { f1 = s#f1 + 48 | s }

    pub def step49(s: State): State = { f1 = s#f1 + 49 | s }

    pub def step50(s: State): State = { f1 = s#f1 + 50 | s }

    pub def step51(s: State): State = { f1 = s#f1 + 51 | s }

    pub def step52(s: State): State = { f1 = s#f1 + 52 | s }

    pub def step53(s: State): State = { f1 = s#f1 + 53 | s }

    pub def step54(s: State): State = { f1 = s#f1 + 54 | s }

    pub def step55(s: State): State = { f1 = s#f1 + 55 | s }

    pub def step56(s: State): State = { f1 = s#f1 + 56 | s }

    pub def step57(s: State): State = { f1 = s#f1 + 57 | s }

    pub def step58(s: State): State = { f1 = s#f1 + 58 | s }

    pub def step59(s: State): State = { f1 = s#f1 + 59 | s }

    pub def step60(s: State): State = { f1 = s#f1 + 60 | s }

    pub def step61(s: State): State = { f1 = s#f1 + 61 | s }

    pub def step62(s: State): State = { f1 = s#f1 + 62 | s }

    pub def step63(s: State): State = { f1 = s#f1 + 63 | s }

    pub def step64(s: State): State = { f1 = s#f1 + 64 | s }

    pub def step65(s: State): State = { f1 = s#f1 + 65 | s }

    pub def step66(s: State): State = { f1 = s#f1 + 66 | s }

    pub def step67(s: State): State = { f1 = s#f1 + 67 | s }

    pub def step68(s: State): State = { f1 = s#f1 + 68 | s }

    pub def step69(s: State): State = { f1 = s#f1 + 69 | s }

    pub def step70(s: State): State = { f1 = s#f1 + 70 | s }

    pub def step71(s: State): State = { f1 = s#f1 + 71 | s }

    pub def step72(s: State): State = { f1 = s#f1 + 72 | s }

    pub def step73(s: State): State = { f1 = s#f1 + 73 | s }

    pub def step74(s: State): State = { f1 = s#f1 + 74 | s }

    pub def step75(s: State): State = { f1 = s#f1 + 75 | s }

    pub def step76(s: State): State = { f1 = s#f1 + 76 | s }

    pub def step77(s: State): State = { f1 = s#f1 + 77 | s }

    pub def step78(s: State): State = { f1 = s#f1 + 78 | s }

    pub def step79(s: State): State = { f1 = s#f1 + 79 | s }

    pub def step80(s: State): State = { f1 = s#f1 + 80 | s }

    pub def step81(s: State): State = { f1 = s#f1 + 81 | s }

    pub def step82(s: State): State = { f1 = s#f1 + 82 | s }

    pub def step83(s: State): State = { f1 = s#f1 + 83 | s }

    pub def step84(s: State): State = { f1 = s#f1 + 84 | s }

    pub def step85(s: State): State = { f1 = s#f1 + 85 | s }

    pub def step86(s: State): State = { f1 = s#f1 + 86 | s }

    pub def step87(s: State): State = { f1 = s#f1 + 87 | s }

    pub def step88(s: State): State = { f1 = s#f1 + 88 | s }

    pub def step89(s: State): State = { f1 = s#f1 + 89 | s }

    pub def step90(s: State): State = { f1 = s#f1 + 90 | s }

    pub def step91(s: State): State = { f1 = s#f1 + 91 | s }

    pub def step92(s: State): State = { f1 = s#f1 + 92 | s }

    pub def step93(s: State): State = { f1 = s#f1 + 93 | s }

    pub def step94(s: State): State = { f1 = s#f1 + 94 | s }

    pub def step95(s: State): State = { f1 = s#f1 + 95 | s }

    pub def step96(s: State): State = { f1 = s#f1 + 96 | s }

    pub def step97(s: State): State = { f1 = s#f1 + 97 | s }

    pub def step98(s: State): State = { f1 = s#f1 + 98 | s }

    pub def step99(s: State): State = { f1 = s#f1 + 99 | s }

    pub def step100(s: State): State = { f1 = s#f1 + 100 | s }
}
