// Length-limited canonical Huffman construction for the encode pipeline:
// frequencies in, (code lengths, bit-reversed code words) out.
//

///|
priv struct Node {
  lit : Int
  freq : Int
}

///|
priv struct LevelInfo {
  mut level : Int
  mut last_freq : Int
  mut next_char_freq : Int
  mut next_pair_freq : Int
  mut needed : Int
}

///|
fn LevelInfo::new() -> LevelInfo {
  { level: 0, last_freq: 0, next_char_freq: 0, next_pair_freq: 0, needed: 0 }
}

///|
fn reverse_bits(number : UInt, bit_length : Int) -> UInt {
  reverse16(number << (16 - bit_length))
}

///|
/// Number of codes assigned to each bit length (index = length). Requires
/// `nodes` sorted by ascending frequency, with `n >= 3`.
fn bit_counts(nodes : Array[Node], n : Int, max_bits_in : Int) -> Array[Int] {
  let maxi = 2147483647
  let mut max_bits = max_bits_in
  if max_bits > n - 1 {
    max_bits = n - 1
  }
  let fr = fn(i : Int) -> Int { if i < n { nodes[i].freq } else { maxi } }
  let levels : Array[LevelInfo] = []
  for _i in 0..<17 {
    levels.push(LevelInfo::new())
  }
  let leaf_counts : Array[Array[Int]] = []
  for _i in 0..<17 {
    leaf_counts.push(Array::make(17, 0))
  }
  for level in 1..<=max_bits {
    levels[level].level = level
    levels[level].last_freq = fr(1)
    levels[level].next_char_freq = fr(2)
    levels[level].next_pair_freq = fr(0) + fr(1)
    levels[level].needed = 0
    leaf_counts[level][level] = 2
    if level == 1 {
      levels[level].next_pair_freq = maxi
    }
  }
  levels[max_bits].needed = 2 * n - 4
  let mut level = max_bits
  for ;; {
    let lv = levels[level]
    if lv.next_pair_freq == maxi && lv.next_char_freq == maxi {
      lv.needed = 0
      levels[level + 1].next_pair_freq = maxi
      level = level + 1
      continue
    }
    let prev_freq = lv.last_freq
    if lv.next_char_freq < lv.next_pair_freq {
      let nn = leaf_counts[level][level] + 1
      lv.last_freq = lv.next_char_freq
      leaf_counts[level][level] = nn
      lv.next_char_freq = fr(nn)
    } else {
      lv.last_freq = lv.next_pair_freq
      for i in 0..<level {
        leaf_counts[level][i] = leaf_counts[level - 1][i]
      }
      levels[lv.level - 1].needed = 2
    }
    lv.needed = lv.needed - 1
    if lv.needed == 0 {
      if lv.level == max_bits {
        break
      }
      levels[lv.level + 1].next_pair_freq = prev_freq + lv.last_freq
      level = level + 1
    } else {
      while levels[level - 1].needed > 0 {
        level = level - 1
      }
    }
  }
  let bit_count = Array::make(max_bits + 1, 0)
  let counts = leaf_counts[max_bits]
  let mut bits = 1
  for lvl = max_bits; lvl > 0; lvl = lvl - 1 {
    bit_count[bits] = counts[lvl] - counts[lvl - 1]
    bits = bits + 1
  }
  bit_count
}

///|
fn assign_codes(
  bit_count : Array[Int],
  nodes : Array[Node],
  code_len : Array[Int],
  code_val : Array[UInt],
) -> Unit {
  let mut code = 0
  let mut rem = nodes.length()
  for nlen in 0..<bit_count.length() {
    code = code << 1
    let bits = bit_count[nlen]
    if nlen == 0 || bits == 0 {
      continue
    }
    let chunk : Array[Node] = []
    for k in (rem - bits)..<rem {
      chunk.push(nodes[k])
    }
    chunk.sort_by((a, b) => a.lit - b.lit)
    for node in chunk {
      code_val[node.lit] = reverse_bits(
        code.reinterpret_as_uint() & 0xFFFF,
        nlen,
      )
      code_len[node.lit] = nlen
      code = code + 1
    }
    rem = rem - bits
  }
}

///|
/// Build length-limited canonical Huffman codes for `size` symbols from their
/// frequencies. Returns (code lengths, bit-reversed codes).
fn gen_huffman(
  freq : Array[Int],
  size : Int,
  max_bits : Int,
) -> (Array[Int], Array[UInt]) {
  let code_len = Array::make(size, 0)
  let code_val = Array::make(size, 0U)
  let nodes : Array[Node] = []
  for i in 0..<size {
    if freq[i] != 0 {
      nodes.push({ lit: i, freq: freq[i] })
    }
  }
  let count = nodes.length()
  if count == 0 {
    return (code_len, code_val)
  }
  if count <= 2 {
    for k in 0..<count {
      code_len[nodes[k].lit] = 1
      code_val[nodes[k].lit] = reverse_bits(k.reinterpret_as_uint(), 1)
    }
    return (code_len, code_val)
  }
  nodes.sort_by((a, b) => {
    if a.freq != b.freq {
      a.freq - b.freq
    } else {
      a.lit - b.lit
    }
  })
  let bit_count = bit_counts(nodes, count, max_bits)
  assign_codes(bit_count, nodes, code_len, code_val)
  (code_len, code_val)
}
