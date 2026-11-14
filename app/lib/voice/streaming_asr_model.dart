class StreamingAsrModel {
  const StreamingAsrModel({required this.encoder, required this.decoder, required this.joiner, required this.tokens});

  final String encoder;
  final String decoder;
  final String joiner;
  final String tokens;
}
