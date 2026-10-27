mod TestSave {

    @Test
    def testParse(): Unit \ Assert = Assert.assertEq(expected = 3, Save.parse("abc"))

    @Test
    def testParseEmpty(): Unit \ Assert = Assert.assertEq(expected = 0, Save.parse(""))

}
