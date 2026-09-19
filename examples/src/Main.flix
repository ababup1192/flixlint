def main(): Unit \ IO =
    println(Runner.transact(() -> Orders.receipt("1")))
