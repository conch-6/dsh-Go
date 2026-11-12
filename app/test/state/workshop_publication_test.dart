import 'package:dsh_app/state/workshop_publication.dart';
import 'package:dsh_app/state/workshop_publish_sources.dart';
import 'package:flutter_test/flutter_test.dart';

WorkshopPublicationInput _valid() => WorkshopPublicationInput(
  id: 'cat', titleZh: '小猫', titleEn: 'Cat', author: 'Author',
  license: 'CC0-1.0', source: 'https://source.example/cat',
);

void main() {
  test('new input has explicit rights failure and field codes without user prose', () {
    final empty = WorkshopPublicationInput().errors();
    expect(empty.keys, containsAll(['id', 'titleZh', 'titleEn', 'author', 'license', 'source', 'rightsConfirmed']));
    expect(empty.values.every((code) => code.startsWith('workshop_')), isTrue);
    expect(_valid().errors(), {'rightsConfirmed': 'workshop_rights_required'});
    expect(_valid().errors(includeRights: false), isEmpty);
    expect(_valid().copyWith(rightsConfirmed: true).errors(), isEmpty);
  });

  test('description and tag bounds use exact strings and Unicode code points', () {
    final tags = [for (var i = 0; i < 8; i++) '$i${'猫' * 31}'];
    final input = _valid().copyWith(description: '🙂' * 512, tags: tags);
    tags[0] = 'changed';
    expect(input.tags.first, '0${'猫' * 31}');
    expect(input.errors(includeRights: false), isEmpty);
    expect(() => input.tags.add('later'), throwsUnsupportedError);
    expect(input.copyWith(description: '🙂' * 513).errors()['description'], 'workshop_bad_description');
    expect(input.copyWith(description: '\n').errors()['description'], 'workshop_bad_description');
    for (final invalid in [<String>['same', 'same'], [''], ['猫' * 33], List.generate(9, (i) => '$i')]) {
      expect(input.copyWith(tags: invalid).errors()['tags'], 'workshop_bad_tags');
    }
    expect(input.copyWith(tags: ['Cat', 'cat', 'é', 'e\u0301']).errors(includeRights: false), isEmpty);
  });

  test('publication adds archive identity later and retains display metadata', () {
    final input = _valid().copyWith(description: 'Description', tags: ['cat']);
    final declaration = input.declaration('pet');
    expect(declaration.containsKey('sha256'), isFalse);
    expect(declaration.containsKey('size'), isFalse);
    expect(declaration.containsKey('rightsConfirmed'), isFalse);
    final metadata = input.publication('pet').withArchive('a' * 64, 4);
    expect(metadata.description, 'Description');
    expect(metadata.tags, ['cat']);
    expect(metadata.sha256, 'a' * 64);
    expect(metadata.size, 4);
    expect(_valid().declaration('pet').containsKey('description'), isFalse);
    expect(_valid().declaration('pet').containsKey('tags'), isFalse);
  });

  test('invalid metadata stays in its field and copied input retains unedited values', () {
    final invalid = _valid().copyWith(id: '../bad', version: 'future', minApp: '',
      titleZh: ' ', author: '', license: 'unknown', source: 'http://source.example');
    expect(invalid.errors(includeRights: false).keys,
      containsAll(['id', 'version', 'minApp', 'titleZh', 'author', 'license', 'source']));
    expect(invalid.titleEn, 'Cat');
  });

  test('restoring original confirmed metadata does not create a new unchecked intent', () {
    final metadata = _valid().copyWith(description: 'Original', tags: ['original'])
      .publication('pet').withArchive('a' * 64, 4);
    final restored = WorkshopPublicationInput.fromMetadata(metadata);
    expect(restored.rightsConfirmed, isTrue);
    expect(restored.errors(), isEmpty);
    expect(restored.description, 'Original');
    expect(restored.tags, ['original']);
    expect(restored.publication('pet').withArchive(metadata.sha256, metadata.size).toJson(), metadata.toJson());
  });

  test('source prefill uses public pack attribution and never copies a companion name', () {
    final pet = const WorkshopPublishSource(kind: 'pet', localId: 'user-cat', name: 'Cat',
      author: 'Author', license: 'CC0-1.0', source: 'https://source.example/cat').initialInput();
    expect(pet.id, 'cat');
    expect(pet.titleZh, 'Cat');
    expect(pet.rightsConfirmed, isFalse);
    final companion = const WorkshopPublishSource(kind: 'companion', localId: 'companion',
      name: 'Private nickname', author: 'Author').initialInput();
    expect(companion.titleZh, isEmpty);
    expect(companion.titleEn, isEmpty);
    expect(companion.author, 'Author');
    expect(companion.rightsConfirmed, isFalse);
  });
}
