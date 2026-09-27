import Foundation

/// The rules to paste into the Firebase console (Realtime Database → Rules),
/// shown in Settings so a grown-up can copy them, and in docs/firebase_*.md.
///
/// Nothing is readable or writable unless a rule below says so, and every
/// rule needs someone signed in (Ablox signs in anonymously). In short:
///
/// - `users/<uid>/profile`: written by its owner; read by its owner and by
///   friends who have added each other.
/// - `codes/<code>`: friend codes; claimed once, looked up one at a time,
///   never listed.
/// - `requests/<to>/<from>`: a friend request, sent by `from`, read and
///   cleared by `to`.
/// - `friends/<uid>/<other>`: who `uid` has added; only after a request.
/// - `chats/<a>_<b>`: the two friends' chat; 200 characters a line, each
///   line written once by whoever says it.
/// - `lobby/<room>`: internet rooms, read by everyone signed in, written by
///   the room's host.
/// - `relay/<room>`: the game's own encrypted stream in pieces, between the
///   host and each guest, and nobody else.
public enum CloudRules {

    public static let json = #"""
    {
      "rules": {
        ".read": false,
        ".write": false,

        "users": {
          "$uid": {
            "profile": {
              ".read": "auth != null && (auth.uid === $uid || (root.child('friends').child($uid).child(auth.uid).exists() && root.child('friends').child(auth.uid).child($uid).exists()))",
              ".write": "auth != null && auth.uid === $uid",
              ".validate": "newData.hasChildren(['avatar', 'code', 'online', 'seen'])",
              "avatar": { ".validate": "newData.hasChildren(['displayName']) && newData.child('displayName').isString() && newData.child('displayName').val().length <= 24" },
              "code": { ".validate": "newData.isString() && newData.val().length <= 8" },
              "online": { ".validate": "newData.isBoolean()" },
              "seen": { ".validate": "newData.isNumber() && newData.val() <= now + 60000" },
              "game": { ".validate": "newData.isString() && newData.val().length <= 60" },
              "room": { ".validate": "newData.isString() && newData.val().length <= 64" },
              "$other": { ".validate": false }
            }
          }
        },

        "codes": {
          "$code": {
            ".read": "auth != null",
            ".write": "auth != null && ((!data.exists() && newData.val() === auth.uid) || (data.val() === auth.uid && !newData.exists()))",
            ".validate": "$code.matches(/^[A-Z2-9]{8}$/)"
          }
        },

        "requests": {
          "$to": {
            ".read": "auth != null && auth.uid === $to",
            "$from": {
              ".write": "auth != null && (auth.uid === $from || (auth.uid === $to && !newData.exists()))",
              ".validate": "newData.hasChildren(['name', 'at']) && newData.child('name').isString() && newData.child('name').val().length <= 24 && newData.child('at').isNumber() && newData.child('at').val() <= now + 60000"
            }
          }
        },

        "friends": {
          "$uid": {
            ".read": "auth != null && auth.uid === $uid",
            "$other": {
              ".write": "auth != null && auth.uid === $uid && (!newData.exists() || root.child('requests').child($other).child($uid).exists() || root.child('requests').child($uid).child($other).exists() || root.child('friends').child($other).child($uid).exists())",
              ".validate": "newData.isBoolean()"
            }
          }
        },

        "chats": {
          "$pair": {
            ".read": "auth != null && ($pair.beginsWith(auth.uid + '_') || $pair.endsWith('_' + auth.uid)) && root.child('friends').child(auth.uid).child($pair.replace(auth.uid, '').replace('_', '')).exists() && root.child('friends').child($pair.replace(auth.uid, '').replace('_', '')).child(auth.uid).exists()",
            "$message": {
              ".write": "auth != null && ($pair.beginsWith(auth.uid + '_') || $pair.endsWith('_' + auth.uid)) && (!newData.exists() || (!data.exists() && root.child('friends').child(auth.uid).child($pair.replace(auth.uid, '').replace('_', '')).exists() && root.child('friends').child($pair.replace(auth.uid, '').replace('_', '')).child(auth.uid).exists()))",
              ".validate": "newData.hasChildren(['from', 'text', 'at']) && newData.child('from').val() === auth.uid && newData.child('text').isString() && newData.child('text').val().length > 0 && newData.child('text').val().length <= 200 && newData.child('at').isNumber() && newData.child('at').val() <= now + 60000"
            }
          }
        },

        "lobby": {
          ".read": "auth != null",
          ".indexOn": ["at"],
          "$room": {
            ".write": "auth != null && ((!data.exists() && newData.child('host').val() === auth.uid) || data.child('host').val() === auth.uid)",
            ".validate": "newData.hasChildren(['host', 'hostName', 'world', 'worldID', 'players', 'capacity', 'protocol', 'code', 'salt', 'at']) && newData.child('host').val() === auth.uid && newData.child('hostName').isString() && newData.child('hostName').val().length <= 40 && newData.child('world').isString() && newData.child('world').val().length <= 60 && newData.child('players').isNumber() && newData.child('capacity').isNumber() && newData.child('capacity').val() <= 50 && newData.child('code').isString() && newData.child('code').val().length <= 12 && newData.child('salt').isString() && newData.child('salt').val().length <= 64 && newData.child('at').isNumber() && newData.child('at').val() <= now + 60000"
          }
        },

        "relay": {
          "$room": {
            ".write": "auth != null && !newData.exists() && root.child('lobby').child($room).child('host').val() === auth.uid",
            "links": {
              ".read": "auth != null && root.child('lobby').child($room).child('host').val() === auth.uid",
              "$link": {
                ".read": "auth != null && (data.child('guest').val() === auth.uid || root.child('lobby').child($room).child('host').val() === auth.uid)",
                ".write": "auth != null && ((!data.exists() && newData.child('guest').val() === auth.uid && root.child('lobby').child($room).exists()) || (data.child('guest').val() === auth.uid && !newData.exists()) || (root.child('lobby').child($room).child('host').val() === auth.uid && !newData.exists()))"
              }
            },
            "up": {
              ".read": "auth != null && root.child('lobby').child($room).child('host').val() === auth.uid",
              "$link": {
                ".write": "auth != null && (root.child('relay').child($room).child('links').child($link).child('guest').val() === auth.uid || root.child('lobby').child($room).child('host').val() === auth.uid)",
                "$piece": { ".validate": "$piece.matches(/^[0-9]{10}$/) && newData.isString() && newData.val().length <= 360000" }
              }
            },
            "down": {
              "$link": {
                ".read": "auth != null && root.child('relay').child($room).child('links').child($link).child('guest').val() === auth.uid",
                ".write": "auth != null && (root.child('lobby').child($room).child('host').val() === auth.uid || root.child('relay').child($room).child('links').child($link).child('guest').val() === auth.uid)",
                "$piece": { ".validate": "$piece.matches(/^[0-9]{10}$/) && newData.isString() && newData.val().length <= 360000" }
              }
            }
          }
        }
      }
    }
    """#
}
