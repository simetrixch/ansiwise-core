/// IPv4 range arithmetic for the steps that read addresses off a machine.
///
/// The arithmetic is done in Dart's 64-bit integers and masked back to 32 bits explicitly at the
/// end. A 32-bit implementation overflows on a `/0`, where the mask is meant to be zero so that
/// everything overlaps, and produces the opposite answer.
library;

/// Whether [value] is a range this arithmetic can read — an address, a slash and a prefix.
bool isCidr(String value) => _Range.parse(value) != null;

/// Whether two IPv4 ranges share any address.
///
/// Two ranges overlap exactly when their network addresses are equal under the SHORTER of the two
/// prefixes. The obvious implementation — testing whether one contains the other's network address
/// — gets containment right in one direction and wrong in the other.
/// **A range this cannot read is a REFUSAL and never an answer.** "No overlap" is the answer that
/// lets the caller carry on: a step refusing a range that collides with the machine's own network
/// would pass on a typo, and every reader of that run would see a check that had run and found
/// nothing. Ask [isCidr] first where a value may legitimately not be one.
bool cidrOverlap(String left, String right) {
  final _Range? a = _Range.parse(left);
  final _Range? b = _Range.parse(right);
  if (a == null || b == null) {
    final String unreadable = a == null ? left : right;
    throw FormatException(
      'this is not an address range, so whether it overlaps anything cannot be answered — a range '
      'is a dotted quad, a slash and a prefix length of 0 to 32',
      unreadable,
    );
  }
  final int prefix = a.prefix < b.prefix ? a.prefix : b.prefix;
  final int mask = prefix == 0 ? 0 : (((1 << 32) - (1 << (32 - prefix))) & 0xFFFFFFFF);
  return (a.address & mask) == (b.address & mask);
}

/// Whether [address] — a dotted quad with no prefix — lies inside [cidr].
///
/// Refuses on either side being unreadable, for the reason [cidrOverlap] gives. A caller holding an
/// address it read off a machine asks [isCidr] about it first.
bool cidrContains(String cidr, String address) => cidrOverlap(cidr, '$address/32');

/// One IPv4 range, as an address and a prefix length.
final class _Range {
  const _Range(this.address, this.prefix);

  /// The range [value] describes, or null when it is not one.
  static _Range? parse(String value) {
    final List<String> halves = value.split('/');
    if (halves.length != 2) {
      return null;
    }
    final int? prefix = int.tryParse(halves[1]);
    if (prefix == null || prefix < 0 || prefix > 32) {
      return null;
    }
    final int? address = _address(halves[0]);
    return address == null ? null : _Range(address, prefix);
  }

  /// The dotted quad [value] as a number, or null when it is not one.
  static int? _address(String value) {
    final List<String> octets = value.split('.');
    if (octets.length != 4) {
      return null;
    }
    int address = 0;
    for (final String octet in octets) {
      final int? part = int.tryParse(octet);
      if (part == null || part < 0 || part > 255 || (octet.length > 1 && octet.startsWith('0'))) {
        return null;
      }
      address = (address << 8) | part;
    }
    return address;
  }

  final int address;
  final int prefix;
}
