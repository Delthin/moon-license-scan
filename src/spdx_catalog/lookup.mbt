///|
pub fn lookup(identifier : StringView, exception : Bool) -> (String, Bool)? {
  let table = if exception { exceptions } else { licenses }
  let key = identifier.to_owned().to_lower()
  for low = 0, high = table.length(); low < high; {
    let middle = low + (high - low) / 2
    let (normalized, name, deprecated) = table[middle]
    if key < normalized {
      continue low, middle
    } else if key > normalized {
      continue middle + 1, high
    } else {
      return Some((name, deprecated))
    }
  }
  None
}
