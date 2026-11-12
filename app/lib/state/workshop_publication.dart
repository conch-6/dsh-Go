import '../workshop/workshop_models.dart';
import '../workshop/workshop_repository.dart';

class WorkshopPublicationInput {
  WorkshopPublicationInput({this.id = '', this.version = '1.0.0', this.minApp = '1.0.0',
    this.titleZh = '', this.titleEn = '', this.author = '', this.license = '',
    this.source = '', this.description = '', List<String> tags = const [],
    this.rightsConfirmed = false}) : tags = List.unmodifiable(tags);

  final String id, version, minApp, titleZh, titleEn, author, license, source, description;
  final List<String> tags;
  final bool rightsConfirmed;

  Map<String, String> errors({bool includeRights = true}) => Map.unmodifiable({
    if (!workshopId(id)) 'id': 'workshop_bad_id',
    if (WorkshopVersion.tryParse(version) == null) 'version': 'workshop_bad_version',
    if (WorkshopVersion.tryParse(minApp) == null) 'minApp': 'workshop_bad_min_app',
    if (!workshopText(titleZh, 120)) 'titleZh': 'workshop_bad_title',
    if (!workshopText(titleEn, 120)) 'titleEn': 'workshop_bad_title',
    if (!workshopText(author, 256)) 'author': 'workshop_bad_author',
    if (!workshopLicenses.contains(license)) 'license': 'workshop_bad_license',
    if (!workshopSource(source)) 'source': 'workshop_bad_source',
    if (description.isNotEmpty && !workshopText(description, 512)) 'description': 'workshop_bad_description',
    if (tags.length > 8 || tags.any((tag) => !workshopText(tag, 32)) || tags.toSet().length != tags.length)
      'tags': 'workshop_bad_tags',
    if (includeRights && !rightsConfirmed) 'rightsConfirmed': 'workshop_rights_required',
  });

  Map<String, Object?> declaration(String kind) => {
    'kind': kind, 'id': id, 'version': version, 'minApp': minApp,
    'title': {'zh': titleZh, 'en': titleEn}, 'author': author,
    'license': license, 'source': source,
    if (description.isNotEmpty) 'description': description,
    if (tags.isNotEmpty) 'tags': tags,
  };

  WorkshopPublication publication(String kind) => WorkshopPublication(declaration(kind));

  WorkshopPublicationInput copyWith({String? id, String? version, String? minApp,
    String? titleZh, String? titleEn, String? author, String? license, String? source,
    String? description, List<String>? tags, bool? rightsConfirmed}) => WorkshopPublicationInput(
    id: id ?? this.id, version: version ?? this.version, minApp: minApp ?? this.minApp,
    titleZh: titleZh ?? this.titleZh, titleEn: titleEn ?? this.titleEn,
    author: author ?? this.author, license: license ?? this.license, source: source ?? this.source,
    description: description ?? this.description, tags: tags ?? this.tags,
    rightsConfirmed: rightsConfirmed ?? this.rightsConfirmed,
  );

  factory WorkshopPublicationInput.fromMetadata(WorkshopMetadata metadata) => WorkshopPublicationInput(
    id: metadata.id, version: metadata.version, minApp: metadata.minApp,
    titleZh: metadata.title['zh']!, titleEn: metadata.title['en']!, author: metadata.author,
    license: metadata.license, source: metadata.source, description: metadata.description,
    tags: metadata.tags, rightsConfirmed: true,
  );
}
