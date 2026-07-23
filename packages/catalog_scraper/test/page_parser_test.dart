import 'package:catalog_scraper/catalog_scraper.dart';
import 'package:test/test.dart';

void main() {
  final root = Uri.parse('https://sites.google.com/view/biblioteca');
  final page = Uri.parse(
    'https://sites.google.com/view/biblioteca/temporada-2',
  );
  final parser = GoogleSitesPageParser(siteRoot: root);

  test('extrae episodios y enlaces usando atributos semánticos', () {
    final result = parser.parse(
      url: page,
      html: _pageHtml(firstDriveId: 'drive-a'),
    );

    expect(
      result.internalLinks,
      contains(root.resolve('/view/biblioteca/otra')),
    );
    expect(result.seriesKey, 'ninjago');
    expect(result.season?.displayNumber, 2);
    expect(result.season?.canonicalCode, 2);
    expect(result.season?.episodes, hasLength(3));

    final first = result.season!.episodes.first;
    expect(first.number, 1);
    expect(first.title, 'El inicio');
    expect(first.mediaSource?.remoteId, 'drive-a');
    expect(first.mediaSource?.thumbnailUrl.host, 'drive.google.com');

    final announced = result.season!.episodes.last;
    expect(announced.number, 3);
    expect(announced.availability, ScrapedAvailability.announced);
  });

  test('cambiar Drive conserva identidad y hash lógico', () {
    final before = parser.parse(
      url: page,
      html: _pageHtml(firstDriveId: 'drive-a'),
    );
    final after = parser.parse(
      url: page,
      html: _pageHtml(firstDriveId: 'drive-reemplazado'),
    );

    final oldEpisode = before.season!.episodes.first;
    final newEpisode = after.season!.episodes.first;
    expect(newEpisode.logicalKey, oldEpisode.logicalKey);
    expect(newEpisode.logicalHash, oldEpisode.logicalHash);
    expect(
      newEpisode.mediaSource!.locatorHash,
      isNot(oldEpisode.mediaSource!.locatorHash),
    );
  });

  test('prefiere Streamtape cuando la página ofrece ambos proveedores', () {
    final html = _pageHtml(firstDriveId: 'drive-a').replaceFirst(
      '<p>Ep1: El inicio</p>',
      '<a href="https://streamtape.com/e/stream-a/">El inicio</a>'
          '<p>Ep1: El inicio</p>',
    );
    final result = parser.parse(url: page, html: html);

    final first = result.season!.episodes.first;
    expect(first.mediaSource?.provider, 'streamtape');
    expect(first.mediaSource?.remoteId, 'stream-a');
    expect(first.mediaSource?.openUrl.host, 'streamtape.com');
    expect(first.mediaSource?.thumbnailUrl.host, 'drive.google.com');
    expect(first.mediaSources.map((source) => source.provider), [
      'streamtape',
      'google_drive',
    ]);
    expect(result.season!.episodes[1].mediaSource?.provider, 'google_drive');
  });

  test('incorpora episodios publicados únicamente en Streamtape /v', () {
    final html = _pageHtml(firstDriveId: 'drive-a').replaceFirst(
      '</section>',
      '''
      <a href="https://www.google.com/url?q=https%3A%2F%2Fstreamtape.com%2Fv%2Fstream-c%2F2X4_El_nuevo.mp4">
        <img src="https://example.com/stream-c.jpg">
      </a>
      <a href="https://streamtape.com/v/stream-c/2X4_El_nuevo.mp4">
        Ep4: El nuevo
      </a>
      </section>
      ''',
    );
    final result = parser.parse(url: page, html: html);

    final episode = result.season!.episodes.singleWhere(
      (candidate) => candidate.number == 4,
    );
    expect(episode.title, 'El nuevo');
    expect(episode.logicalKey, 'ninjago/temporada-2/e004');
    expect(episode.mediaSource?.provider, 'streamtape');
    expect(episode.mediaSource?.remoteId, 'stream-c');
    expect(
      episode.mediaSource?.thumbnailUrl,
      Uri.parse('https://example.com/stream-c.jpg'),
    );
  });

  test('conserva texto y enlaces de páginas sin videos', () {
    final result = parser.parse(
      url: root.resolve('/view/biblioteca/orden-cronologico'),
      html: '''
      <html><body><div class="UtePc">
        <h1>Orden cronológico</h1>
        <p>Esta guía explica el orden completo para seguir la historia.</p>
        <h2>Temporadas</h2>
        <p>Primero se deben ver los episodios piloto.</p>
        <a href="https://example.com/listado">Descargar listado</a>
      </div></body></html>
      ''',
    );

    expect(result.season, isNull);
    expect(result.infoPage?.title, 'Orden cronológico');
    expect(result.infoPage?.body, contains('Primero se deben ver'));
    expect(result.infoPage?.links.single.label, 'Descargar listado');
  });

  test('nombra Inicio de forma estable aunque tenga otros encabezados', () {
    final result = parser.parse(
      url: root.resolve('/view/biblioteca/inicio'),
      html: '''
      <html><body><div class="UtePc">
        <h1>LA BIBLIOTECA ELEMENTAL</h1>
        <h1>Redes sociales para seguirnos</h1>
        <p>Bienvenidos al archivo completo de la serie y sus temporadas.</p>
      </div></body></html>
      ''',
    );

    expect(result.infoPage?.title, 'Inicio');
  });

  test('conserva videos extra que repiten el número de un capítulo', () {
    final result = parser.parse(
      url: page,
      html: '''
      <html><body>
        <h1>Temporada 2</h1>
        <div data-embed-doc-id="compilacion">
          <iframe aria-label="Drive, Película completa.mp4"></iframe>
        </div>
        <p>Video completo de la aventura</p>
        <div data-embed-doc-id="episodio-1">
          <iframe aria-label="Drive, 2X1 El inicio.mp4"></iframe>
        </div>
        <p>Ep1: El inicio</p>
        <div data-embed-doc-id="vlog-1">
          <iframe aria-label="Drive, Ninja Vlog 1.mp4"></iframe>
        </div>
        <p>Ep1: Nuestro primer vlog ninja</p>
      </body></html>
      ''',
    );

    final episodes = result.season!.episodes;
    expect(episodes, hasLength(3));
    expect(episodes.map((episode) => episode.logicalKey).toSet(), hasLength(3));
    expect(
      episodes
          .singleWhere((episode) => episode.title == 'El inicio')
          .logicalKey,
      'ninjago/temporada-2/e001',
    );
    expect(
      episodes
          .singleWhere((episode) => episode.title.contains('vlog'))
          .logicalKey,
      contains('nuestro-primer-vlog-ninja'),
    );
  });

  test('humaniza nombres de Drive escritos como slug', () {
    final result = parser.parse(
      url: root.resolve('/view/biblioteca/el-monstruoso-viaje-de-kai'),
      html: '''
      <html><body>
        <h1>El monstruoso viaje de Kai</h1>
        <div data-embed-doc-id="kai">
          <iframe aria-label="Drive, El-monstruoso-viaje-de-Kai-con-subtitulos.mp4"></iframe>
        </div>
      </body></html>
      ''',
    );

    expect(
      result.season!.episodes.single.title,
      'El monstruoso viaje de Kai con subtítulos',
    );
  });
}

String _pageHtml({required String firstDriveId}) =>
    '''
<!doctype html>
<html><body>
  <nav><a href="/view/biblioteca/otra">Otra página</a></nav>
  <h1>Temporada 2</h1>
  <p>Descripción suficientemente extensa para pertenecer a la temporada de prueba.</p>
  <section>
    <div data-embed-doc-id="$firstDriveId"
         data-embed-open-url="https://drive.google.com/open?id=$firstDriveId"
         data-embed-thumbnail-url="https://drive.google.com/thumbnail?id=$firstDriveId"
         data-embed-download-url="https://drive.google.com/uc?id=$firstDriveId&amp;export=download">
      <iframe aria-label="Drive, 2X1 El inicio.mp4"
              data-src="https://drive.google.com/file/d/$firstDriveId/preview"></iframe>
    </div>
    <p>Ep1: El inicio</p>
    <p>Una descripción extensa del primer episodio para comprobar la asociación contextual.</p>
    <div data-embed-doc-id="drive-b">
      <iframe aria-label="Drive, 2X2 El regreso.mp4"></iframe>
    </div>
    <p>Ep2: El regreso</p>
    <p>Ep3: PRÓXIMAMENTE</p>
  </section>
</body></html>
''';
