import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

class AuthService {
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static final GoogleSignIn _googleSignIn = GoogleSignIn();
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  static String? _cachedRole;
  static String? _cachedUserId;

  static User? get currentUser => _auth.currentUser;
  static Stream<User?> get authStateChanges => _auth.authStateChanges();

  static const String roleAdmin = 'admin';
  static const String roleArcheologist = 'archeologist';
  static const String roleViewer = 'viewer';

  static Future<String> getCurrentUserRole() async {
    final user = currentUser;
    if (user == null) return roleViewer;
    if (_cachedUserId == user.uid && _cachedRole != null) return _cachedRole!;

    try {
      final doc = await _firestore.collection('users').doc(user.uid).get();
      final role = doc.data()?['role'] as String? ?? roleViewer;
      _cachedRole = role;
      _cachedUserId = user.uid;
      return role;
    } catch (e) {
      return roleViewer;
    }
  }

  static Future<bool> isCurrentUserAdmin() async {
    return await getCurrentUserRole() == roleAdmin;
  }

  static Future<bool> canCurrentUserEdit() async {
    final role = await getCurrentUserRole();
    return role == roleAdmin || role == roleArcheologist;
  }

  static Future<bool> updateUserRole(String targetUid, String newRole) async {
    try {
      if (!await isCurrentUserAdmin()) return false;
      if (![roleAdmin, roleArcheologist, roleViewer].contains(newRole)) return false;

      await _firestore.collection('users').doc(targetUid).update({'role': newRole});
      if (targetUid == currentUser?.uid) _cachedRole = newRole;
      return true;
    } catch (e) {
      return false;
    }
  }

  static void clearRoleCache() {
    _cachedRole = null;
    _cachedUserId = null;
  }

  static Future<UserCredential> registerWithEmail({
    required String email,
    required String password,
    required String fullName,
  }) async {
    final credential = await _auth.createUserWithEmailAndPassword(
      email: email,
      password: password,
    );
    await credential.user?.updateDisplayName(fullName);
    await _createUserProfile(
      uid: credential.user!.uid,
      email: email,
      fullName: fullName,
    );
    return credential;
  }

  static Future<UserCredential?> loginWithEmail({
    required String email,
    required String password,
  }) async {
    try {
      return await _auth.signInWithEmailAndPassword(email: email, password: password);
    } catch (e) {
      if (_auth.currentUser != null) return null;
      rethrow;
    }
  }

  static Future<UserCredential?> signInWithGoogle() async {
    final googleUser = await _googleSignIn.signIn();
    if (googleUser == null) return null;

    final googleAuth = await googleUser.authentication;
    final credential = GoogleAuthProvider.credential(
      accessToken: googleAuth.accessToken,
      idToken: googleAuth.idToken,
    );

    final userCredential = await _auth.signInWithCredential(credential);

    if (userCredential.additionalUserInfo?.isNewUser ?? false) {
      await _createUserProfile(
        uid: userCredential.user!.uid,
        email: userCredential.user!.email ?? '',
        fullName: userCredential.user!.displayName ?? '',
        photoUrl: userCredential.user!.photoURL,
        provider: 'google',
      );
    }
    return userCredential;
  }

  static Future<void> _createUserProfile({
    required String uid,
    required String email,
    required String fullName,
    String? photoUrl,
    String provider = 'email',
  }) async {
    String assignedRole = roleViewer;
    try {
      final existingUsers = await _firestore.collection('users').limit(1).get();
      if (existingUsers.docs.isEmpty) assignedRole = roleAdmin;
    } catch (e) {
      // ignore
    }

    await _firestore.collection('users').doc(uid).set({
      'uid': uid,
      'email': email,
      'fullName': fullName,
      'photoUrl': photoUrl,
      'provider': provider,
      'role': assignedRole,
      'createdAt': FieldValue.serverTimestamp(),
    });

    _cachedRole = assignedRole;
    _cachedUserId = uid;
  }

  static Future<Map<String, dynamic>?> getUserProfile(String uid) async {
    final doc = await _firestore.collection('users').doc(uid).get();
    return doc.data();
  }

  static Future<void> signOut() async {
    clearRoleCache();
    await _googleSignIn.signOut();
    await _auth.signOut();
  }

  static Future<void> sendPasswordResetEmail(String email) async {
    await _auth.sendPasswordResetEmail(email: email);
  }

  static Stream<QuerySnapshot> getUsersStream() {
    return _firestore.collection('users').snapshots();
  }
}
