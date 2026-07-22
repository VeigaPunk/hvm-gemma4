# BEND2 mailbox keep classifier (source of record).
# Runtime: mailbox-hvm4.sh lowers keep() into HVM4-native IR because bend
# gen-hvm still emits HVM2 nets for non-literal programs.
#
# kind codes: concern=1, diff=2, discovery=3, shutdown-ack=4, else=0
# keep when kind ∈ {1,2,3,4}

def keep(code):
  return (code == 1) + (code == 2) + (code == 3) + (code == 4)

def main:
  return [keep(1), keep(0), keep(2), keep(3), keep(4)]
