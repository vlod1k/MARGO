from app.main import app


def test_update_files_are_public_and_confined_to_release_directory(client, tmp_path, monkeypatch):
    files = next(route.app for route in app.routes if route.name == 'updates')
    monkeypatch.setattr(files, 'directory', str(tmp_path))
    monkeypatch.setattr(files, 'all_directories', [str(tmp_path)])
    (tmp_path / 'latest.json').write_text('{"windows": null}', encoding='utf-8')
    (tmp_path / 'MARGO.apk').write_bytes(b'application-update')
    response = client.get('/updates/latest.json')
    assert response.status_code == 200
    assert response.json() == {'windows': None}
    assert client.get('/updates/MARGO.apk').content == b'application-update'
    assert client.get('/updates/absent.exe').status_code == 404
    assert client.get('/updates/%2e%2e/app/main.py').status_code == 404
