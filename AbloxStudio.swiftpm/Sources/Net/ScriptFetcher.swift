import Foundation

/// Downloads a world's `.absc` files from its `ScriptSource` on GitHub.
///
/// Thin on purpose, like `GameLibrary`: which names are allowed, how big a
/// file may be and which URL to ask are all decided in `ScriptSource`, in the
/// portable core where they are tested. What is left is `URLSession`.
public enum ScriptFetcher {

    public enum FetchError: Error, Equatable {
        case invalidSource
        case badStatus(Int)
        case tooLarge
        case listing(ScriptSource.ListingError)
    }

    public static func message(for error: Error) -> String {
        switch error as? FetchError {
        case .invalidSource?:
            return L("That repository, branch or folder is not valid.")
        case let .badStatus(code)?:
            switch code {
            case 404: return L("Nothing was found there. Check the repository, the branch and the folder, and that the repository is public.")
            case 403, 429: return L("GitHub is limiting requests from this network. Try again in a few minutes.")
            default: return L("GitHub answered with an error ({}).", code)
            }
        case .tooLarge?:
            return L("That download was too big and was refused.")
        case let .listing(problem)?:
            return problem.message
        case nil:
            return L("Could not reach GitHub.")
        }
    }

    /// Every `.absc` in the source's folder, with its text.
    ///
    /// - Parameter knownNames: the files the world already has. If GitHub's
    ///   listing is refused — its unauthenticated limit is sixty an hour per
    ///   network, easy to spend in a classroom — those files are still
    ///   refreshed straight from the raw file server, which has no such limit.
    public static func download(_ source: ScriptSource, knownNames: [String] = [],
                                session: URLSession = .shared) async throws -> [(name: String, source: String)] {
        guard let listingURL = source.listingURL else { throw FetchError.invalidSource }

        var names: [String]
        var fromListing = true
        do {
            var request = URLRequest(url: listingURL)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let data = try await get(request, limit: ScriptSource.Limits.maximumListingBytes, session: session)
            do {
                names = try ScriptSource.parseListing(data).map(\.name)
            } catch let problem as ScriptSource.ListingError {
                throw FetchError.listing(problem)
            }
        } catch FetchError.badStatus(let code) where (code == 403 || code == 429) && !knownNames.isEmpty {
            names = knownNames
            fromListing = false
        }

        var files: [(name: String, source: String)] = []
        for name in names {
            guard let url = source.fileURL(named: name) else { continue }
            let data: Data
            do {
                data = try await get(URLRequest(url: url), limit: ScriptSource.Limits.maximumFileBytes, session: session)
            } catch FetchError.badStatus(let code) where code == 404 && !fromListing {
                // Guessed from the world's own names; that file is simply
                // not in the repository.
                continue
            }
            guard let text = String(data: data, encoding: .utf8) else { continue }
            files.append((name: name, source: text))
        }
        return files
    }

    /// The world with its scripts brought up to date from its source, what
    /// changed, or why it could not be.
    public static func refresh(_ world: WorldDocument,
                               session: URLSession = .shared) async -> (world: WorldDocument, result: ScriptSyncResult?, error: String?) {
        guard let source = world.scriptSource else { return (world, nil, nil) }
        do {
            let files = try await download(source, knownNames: world.scripts.map(\.name), session: session)
            let merged = ScriptSource.merge(files, into: world.scripts)
            var updated = world
            updated.scripts = merged.files
            return (updated, merged.result, nil)
        } catch {
            return (world, nil, message(for: error))
        }
    }

    /// One GET, fresh rather than cached, with the size held to `limit`.
    private static func get(_ request: URLRequest, limit: Int, session: URLSession) async throws -> Data {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw FetchError.badStatus(http.statusCode)
        }
        if response.expectedContentLength > Int64(limit) { throw FetchError.tooLarge }
        guard data.count <= limit else { throw FetchError.tooLarge }
        return data
    }
}
