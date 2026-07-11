# Komga API 調査メモ (Phase 2 / KomgaKit)

出典: `https://raw.githubusercontent.com/gotson/komga/master/komga/docs/openapi.json`
取得日: 2026-07-09

DTO はアプリで実際に使うフィールドのみモデル化し、それ以外（各種 `*Lock` フラグ、
`booksMetadata` 集約、管理系フィールド）は Decodable で無視する（`CodingKeys` に列挙しない）。
Komga のレスポンスは JSON なので、`JSONDecoder` は未知キーを無視する。

## エンドポイント一覧（設計書 4.2 と突き合わせ済み）

| 用途 | メソッド/パス | クエリ |
|---|---|---|
| 認証確認 | `GET /api/v2/users/me` | - |
| ライブラリ一覧 | `GET /api/v1/libraries` | -（配列レスポンス、Pageではない） |
| シリーズ一覧 | `GET /api/v1/series` | `search`, `library_id`(配列), `page`, `size` |
| シリーズ内ブック | `GET /api/v1/series/{seriesId}/books` | `page`, `size` |
| ブック詳細 | `GET /api/v1/books/{bookId}` | - |
| Keep Reading | `GET /api/v1/books` | `read_status=IN_PROGRESS`, `sort=readProgress.readDate,desc`, `page`, `size` |
| On Deck | `GET /api/v1/books/ondeck` | `page`, `size` |
| コレクション一覧 | `GET /api/v1/collections` | `page`, `size` |
| コレクション内シリーズ | `GET /api/v1/collections/{id}/series` | `page`, `size` |
| リードリスト一覧 | `GET /api/v1/readlists` | `page`, `size` |
| リードリスト内ブック | `GET /api/v1/readlists/{id}/books` | `page`, `size` |
| ページ一覧 | `GET /api/v1/books/{bookId}/pages` | -（配列レスポンス） |
| ページ画像 | `GET /api/v1/books/{bookId}/pages/{pageNumber}` | `convert=jpeg|png`（1-based） |
| ファイルDL | `GET /api/v1/books/{bookId}/file` | - |
| サムネイル | `GET /api/v1/{books|series|collections|readlists}/{id}/thumbnail` | - |
| 進捗更新 | `PATCH /api/v1/books/{bookId}/read-progress` | body: ReadProgressUpdateDto |

## サムネイルパスの注意
- book/series は `/{id}/thumbnail`
- collection/readlist も `/api/v1/collections/{id}/thumbnail` / `/api/v1/readlists/{id}/thumbnail`（確認済み）

## スキーマ抜粋（required と使用フィールド）

### PageBookDto など Page ラッパー（Spring Page 形式）
```
content: [T]          (required 扱いで使用)
number: Int           (現在のページ番号, 0-based)
size: Int
totalElements: Int64
totalPages: Int
first: Bool, last: Bool, empty: Bool, numberOfElements: Int
```
→ `Page<T>` は `content/number/size/totalElements/totalPages/first/last/numberOfElements/empty`
   をモデル化。`pageable`/`sort` は無視。

### BookDto (required)
id, name, seriesId, seriesTitle, libraryId, number, media, metadata,
sizeBytes(Int64), size(String), created, lastModified, url, oneshot, deleted, fileHash, fileLastModified
- readProgress は **optional**（未読ブックには無い）
- media: MediaDto, metadata: BookMetadataDto

### MediaDto (required すべて)
status, mediaType, pagesCount(Int32), comment, mediaProfile,
epubDivinaCompatible, epubIsKepub
→ 使用: mediaProfile, mediaType, pagesCount, status

### ReadProgressDto (required すべて)
page(Int32), completed, readDate, created, lastModified, deviceId, deviceName
→ 使用: page, completed, readDate

### BookMetadataDto
title(required), number, numberSort(Float), summary, tags[], authors[AuthorDto],
releaseDate(date, optional), isbn, links[]
→ 使用: title, number, summary, authors

### SeriesDto (required)
id, name, libraryId, metadata(SeriesMetadataDto), booksCount, booksReadCount,
booksUnreadCount, booksInProgressCount, oneshot, ...
→ 使用: id, name, libraryId, metadata, booksCount, booksReadCount, booksUnreadCount, booksInProgressCount

### SeriesMetadataDto
title(required), status, summary, publisher, language, readingDirection(required),
genres[], tags[], ageRating(optional)
- **readingDirection は required**。値の例: `LEFT_TO_RIGHT`, `RIGHT_TO_LEFT`, `VERTICAL`, `WEBTOON`
→ 使用: title, status, summary, readingDirection, publisher, language

### LibraryDto
id(required), name(required), root, unavailable(required) ほか多数のフラグ
→ 使用: id, name, unavailable

### PageDto (required: fileName, mediaType, number, size)
number(Int32, 1-based), fileName, mediaType, size(String), sizeBytes(Int64, optional),
width(optional), height(optional)
→ 使用: number, fileName, mediaType, width, height

### CollectionDto (required すべて)
id, name, ordered, filtered, seriesIds[], createdDate, lastModifiedDate
→ 使用: id, name, ordered, seriesIds

### ReadListDto (required すべて)
id, name, summary, ordered, filtered, bookIds[], createdDate, lastModifiedDate
→ 使用: id, name, summary, ordered, bookIds

### UserDto (required すべて)
id, email, roles[], sharedAllLibraries, sharedLibrariesIds[], labelsAllow[], labelsExclude[]
- ageRestriction は optional
→ 使用: id, email, roles

### ReadProgressUpdateDto (body)
`{ page?: Int32, completed?: Bool }` 両方 optional。
説明: "page can be omitted if completed is set to true. completed can be omitted..."

## 設計書との差異・判断メモ
1. **readingDirection は SeriesMetadataDto の required フィールド**。設計書の想定どおり存在する。
   ただし文字列型（enum ではない）。`RIGHT_TO_LEFT/LEFT_TO_RIGHT/VERTICAL/WEBTOON` を
   `KomgaReadingDirection` enum + `unknown` フォールバックでラップし、生値も保持する。
2. **readProgress は BookDto で optional**。未読ブックにはキー自体が無い → optional にする。
3. `libraries` と `pages` は Page ラッパーではなく **素の配列** レスポンス。
4. Keep Reading は専用エンドポイントではなく `GET /api/v1/books?read_status=IN_PROGRESS&sort=...`。
5. サムネイル画像・ページ画像・ファイルDLは `URLRequest` を返すだけ（本文取得は呼び出し側）。
   これらにも `X-API-Key` ヘッダーを付与する。
