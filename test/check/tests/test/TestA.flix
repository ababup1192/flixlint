mod TestA {
    @Test
    def testOneAndOne(): Unit \ Assert =
        Assert.assertEq(expected = 2, A.f(1))

    @Test
    def testWrong(): Unit \ Assert =
        Assert.assertEq(expected = 3, A.f(1))
}
