# Reads the ledger numbers of a chain database (one per line, ascending) and checks that they run 0..N without a gap (050 was never
# written), ending at N = -v last=N. Prints the problem and exits 1 otherwise. Used by dump-baseline.sh (and its unit test).
BEGIN { prev = -1 }
{ n = $1 + 0
  if (n != prev + 1 && !(prev + 2 == n && n == 51 && prev == 49)) { printf "Gap in the migration chain: %d is followed by %d\n", prev, n; bad = 1 }
  prev = n }
END { if (prev != last) { printf "The chain ends at %d, expected --expect-last %d\n", prev, last; bad = 1 }
      exit bad }
