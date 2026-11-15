/// Match settings for the referee layer (D21): one game or the best of three, who serves
/// first (one camera cannot tell; unknown until a rally is won), and singles or doubles.
///
/// In doubles (Phase 9, D22) the user can also name which partner serves and which one
/// receives the first rally. Player 1 of a side is the one on the left when play starts
/// (the tracker numbers partners left to right); the service order follows from there.
class MatchSetup {
  const MatchSetup({
    this.bestOf = 1,
    this.firstServer,
    this.court = 'singles',
    this.firstServerId,
    this.firstReceiverId,
    this.autoChangeEnds = true,
  });

  final int bestOf;

  /// The side that serves first (near / far), or null when unknown.
  final String? firstServer;

  /// singles or doubles: which lines the calls use and how many players are tracked.
  final String court;

  /// Doubles: the partners who serve and receive the first rally (near_1 ... far_2).
  final String? firstServerId;
  final String? firstReceiverId;

  /// Clip record 1.7: the players change ends by the rules (after each game, and at 11 in
  /// the deciding or only game) and the score goes with them. Off for players who stay put.
  final bool autoChangeEnds;

  bool get doubles => court == 'doubles';

  /// Both doubles slots are known (only then are they sent).
  bool get hasServiceOrder => doubles && firstServerId != null && firstReceiverId != null;

  MatchSetup withBestOf(int value) => MatchSetup(
    bestOf: value,
    firstServer: firstServer,
    court: court,
    firstServerId: firstServerId,
    firstReceiverId: firstReceiverId,
    autoChangeEnds: autoChangeEnds,
  );

  /// A new first-server side: the doubles slots, which belong to a side, are cleared.
  MatchSetup withFirstServer(String? side) =>
      MatchSetup(bestOf: bestOf, firstServer: side, court: court, autoChangeEnds: autoChangeEnds);

  MatchSetup withCourt(String value) => MatchSetup(
    bestOf: bestOf,
    firstServer: firstServer,
    court: value,
    autoChangeEnds: autoChangeEnds,
  );

  MatchSetup withAutoChangeEnds(bool value) => MatchSetup(
    bestOf: bestOf,
    firstServer: firstServer,
    court: court,
    firstServerId: firstServerId,
    firstReceiverId: firstReceiverId,
    autoChangeEnds: value,
  );

  MatchSetup withService({String? serverId, String? receiverId}) => MatchSetup(
    bestOf: bestOf,
    firstServer: firstServer,
    court: court,
    firstServerId: serverId,
    firstReceiverId: receiverId,
    autoChangeEnds: autoChangeEnds,
  );

  /// The match fields of POST /jobs and the live start message.
  Map<String, Object?> toJson() => {
    'best_of': bestOf,
    'first_server': firstServer,
    'auto_change_ends': autoChangeEnds,
    if (hasServiceOrder) ...{
      'first_server_id': firstServerId,
      'first_receiver_id': firstReceiverId,
    },
  };

  @override
  bool operator ==(Object other) =>
      other is MatchSetup &&
      other.bestOf == bestOf &&
      other.firstServer == firstServer &&
      other.court == court &&
      other.firstServerId == firstServerId &&
      other.firstReceiverId == firstReceiverId &&
      other.autoChangeEnds == autoChangeEnds;

  @override
  String toString() =>
      'MatchSetup(bestOf: $bestOf, firstServer: $firstServer, court: $court, '
      'firstServerId: $firstServerId, firstReceiverId: $firstReceiverId, '
      'autoChangeEnds: $autoChangeEnds)';

  @override
  int get hashCode =>
      Object.hash(bestOf, firstServer, court, firstServerId, firstReceiverId, autoChangeEnds);
}

const MatchSetup kDefaultMatchSetup = MatchSetup();
