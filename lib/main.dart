import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:file_picker/file_picker.dart';
import 'dart:async';
import 'dart:convert';

void main() {
  runApp(const JeongseongMktApp());
}

class JeongseongMktApp extends StatelessWidget {
  const JeongseongMktApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '정성마케팅',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const WebViewScreen(),
    );
  }
}

class WebViewScreen extends StatefulWidget {
  const WebViewScreen({super.key});

  @override
  State<WebViewScreen> createState() => _WebViewScreenState();
}

class _WebViewScreenState extends State<WebViewScreen> {
  late final WebViewController controller;
  bool isLoading = true;
  String? lastUrl;
  String mainPageUrl = 'http://jeongseongmkt.com/';
  bool isLoginInProgress = false;
  Timer? loginCheckTimer;
  bool isOAuthInProgress = false;
  bool isLogoutInProgress = false;
  bool isSignupInProgress = false;
  bool isRedirecting = false;
  int retryCount = 0;
  static const int maxRetries = 3;
  List<String> navigationHistory = []; // 네비게이션 히스토리

  @override
  void initState() {
    super.initState();
    _initializeWebView();
    // 초기 URL을 히스토리에 추가
    navigationHistory.add(mainPageUrl);
  }

  void _initializeWebView() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..enableZoom(false)
      ..setUserAgent(
        'Mozilla/5.0 (Linux; Android 10; SM-G975F) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/91.0.4472.120 Mobile Safari/537.36',
      )
      ..addJavaScriptChannel(
        'FileUpload',
        onMessageReceived: (JavaScriptMessage message) {
          _handleFileUploadMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            debugPrint('로딩 진행률: $progress%');
          },
          onPageStarted: (String url) {
            setState(() {
              isLoading = true;
            });
            debugPrint('페이지 시작: $url');

            // 로그아웃 처리
            if (_isLogoutPage(url)) {
              isLogoutInProgress = true;
              _handleLogoutStart();
            }
            // OAuth 로그인 시작 감지
            else if (_isOAuthLogin(url)) {
              isOAuthInProgress = true;
              isLoginInProgress = true;
              _startLoginCheckTimer();
            }
            // 일반 로그인 진행 중인지 확인
            else if (_isLoginRedirect(url) && !_isLoginPage(url)) {
              isLoginInProgress = true;
              _startLoginCheckTimer();
            }
          },
          onPageFinished: (String url) {
            setState(() {
              isLoading = false;
            });
            debugPrint('페이지 완료: $url');

            // URL 변경 감지 및 처리
            _handleUrlChange(url);

            // 로그인/로그아웃 완료 감지를 위한 JavaScript 주입
            _injectLoginDetectionScript();

            // 사업자 회원가입 페이지에서 파일 업로드 기능 활성화
            if (url.contains('/join/biz') || url.contains('biz')) {
              _injectFileUploadScript();
            }

            // 로그아웃 완료 확인
            if (isLogoutInProgress) {
              _checkLogoutCompletion(url);
            }
            // OAuth 로그인 완료 확인
            else if (isOAuthInProgress) {
              _checkOAuthCompletion(url);
            }
            // 일반 로그인 완료 확인
            else if (isLoginInProgress) {
              _checkLoginCompletion(url);
            }
          },

          onNavigationRequest: (NavigationRequest request) {
            debugPrint('네비게이션 요청: ${request.url}');

            // 마이페이지로의 이동은 항상 허용
            if (_isMyPage(request.url)) {
              debugPrint('마이페이지로 이동 허용: ${request.url}');
              return NavigationDecision.navigate;
            }

            // 로그아웃 처리
            if (_isLogoutPage(request.url)) {
              debugPrint('로그아웃 시작: ${request.url}');
              return NavigationDecision.navigate;
            }

            // OAuth 로그인 처리
            if (_isOAuthLogin(request.url)) {
              debugPrint('OAuth 로그인 시작: ${request.url}');
              return NavigationDecision.navigate;
            }

            // OAuth 콜백 처리
            if (_isOAuthCallback(request.url)) {
              debugPrint('OAuth 콜백 감지: ${request.url}');
              _handleOAuthCallback(request.url);
              return NavigationDecision.navigate;
            }

            // 로그인 페이지로의 이동은 허용
            if (_isLoginPage(request.url)) {
              return NavigationDecision.navigate;
            }

            // 로그인 완료 후 리다이렉션 처리
            if (_isLoginRedirect(request.url) && !_isLoginPage(request.url)) {
              _handleLoginRedirect(request.url);
              return NavigationDecision.navigate;
            }

            // 로그인 성공 후 메인페이지로 강제 이동
            if (_isLoginSuccess(request.url)) {
              _redirectToMainPage();
              return NavigationDecision.prevent;
            }

            // 외부 브라우저로 이동하려는 경우 앱 내에서 처리
            if (_shouldHandleInApp(request.url)) {
              return NavigationDecision.navigate;
            }

            return NavigationDecision.navigate;
          },
          onWebResourceError: (WebResourceError error) {
            debugPrint('WebView error: ${error.description}');
            setState(() {
              isLoading = false;
            });

            // OAuth 진행 중 오류 발생 시 처리
            if (isOAuthInProgress) {
              _handleOAuthError(error);
            } else {
              // 일반 오류 처리
              _handleWebViewError(error);
            }
          },
        ),
      )
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) {
          _handleJavaScriptMessage(message.message);
        },
      )
      ..loadRequest(Uri.parse(mainPageUrl));
  }

  // WebView 오류 처리
  void _handleWebViewError(WebResourceError error) {
    debugPrint('WebView 오류: ${error.description}');

    // 재시도 로직
    if (retryCount < maxRetries) {
      retryCount++;
      debugPrint('재시도 중... ($retryCount/$maxRetries)');

      Future.delayed(Duration(seconds: retryCount * 2), () {
        if (mounted) {
          controller.reload();
        }
      });
    } else {
      // 최대 재시도 횟수 초과
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('페이지 로딩에 실패했습니다: ${error.description}'),
          backgroundColor: Colors.red,
          duration: const Duration(seconds: 5),
          action: SnackBarAction(
            label: '재시도',
            onPressed: () {
              retryCount = 0;
              controller.reload();
            },
          ),
        ),
      );
    }
  }

  @override
  void dispose() {
    loginCheckTimer?.cancel();
    super.dispose();
  }

  // 로그아웃 페이지 감지
  bool _isLogoutPage(String url) {
    return url.contains('/logout') ||
        url.contains('logout') ||
        url.contains('signout') ||
        url.contains('sign-out') ||
        url.contains('logoff');
  }

  // 로그아웃 시작 처리
  void _handleLogoutStart() {
    debugPrint('로그아웃 시작');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('로그아웃 처리 중입니다...'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // 로그아웃 완료 확인
  void _checkLogoutCompletion(String url) {
    debugPrint('로그아웃 완료 확인: $url');

    // 로그아웃 완료 후 로그인 페이지나 메인페이지로 이동
    if (url.contains('jeongseongmkt.com') &&
        (url.contains('login') ||
            !url.contains('logout') && !url.contains('signout'))) {
      isLogoutInProgress = false;

      // 성공 메시지 표시
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('로그아웃이 완료되었습니다.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      // 메인페이지로 리다이렉션
      _redirectToMainPage();
    }
  }

  // OAuth 로그인 감지
  bool _isOAuthLogin(String url) {
    return url.contains('kakao.com/oauth') ||
        url.contains('accounts.kakao.com') ||
        url.contains('kauth.kakao.com') ||
        url.contains('oauth.kakao.com') ||
        url.contains('nid.naver.com/oauth') ||
        url.contains('accounts.google.com/oauth') ||
        url.contains('accounts.google.com/signin');
  }

  // OAuth 콜백 감지
  bool _isOAuthCallback(String url) {
    return url.contains('kakao') &&
            (url.contains('code=') || url.contains('access_token=')) ||
        url.contains('naver') &&
            (url.contains('code=') || url.contains('access_token=')) ||
        url.contains('google') &&
            (url.contains('code=') || url.contains('access_token='));
  }

  // OAuth 콜백 처리
  void _handleOAuthCallback(String url) {
    debugPrint('OAuth 콜백 처리: $url');

    // 성공 메시지 표시
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('로그인 처리 중입니다...'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );

    // 잠시 대기 후 메인페이지로 리다이렉션
    Future.delayed(const Duration(seconds: 3), () {
      if (mounted) {
        _redirectToMainPage();
      }
    });
  }

  // OAuth 완료 확인
  void _checkOAuthCompletion(String url) {
    debugPrint('OAuth 완료 확인: $url');

    // 이미 리다이렉션 중이면 중복 처리 방지
    if (isRedirecting) {
      debugPrint('리다이렉션 중이므로 OAuth 완료 처리 건너뜀');
      return;
    }

    // OAuth 콜백 URL이거나 메인페이지로 돌아온 경우
    if (_isOAuthCallback(url) ||
        (url.contains('jeongseongmkt.com') && !url.contains('login'))) {
      isOAuthInProgress = false;
      isLoginInProgress = false;
      loginCheckTimer?.cancel();

      // 성공 메시지 표시
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('로그인이 완료되었습니다.'),
          backgroundColor: Colors.green,
          duration: Duration(seconds: 2),
        ),
      );

      // 메인페이지로 리다이렉션
      _redirectToMainPage();
    }
  }

  // OAuth 오류 처리
  void _handleOAuthError(WebResourceError error) {
    debugPrint('OAuth 오류: ${error.description}');
    isOAuthInProgress = false;
    isLoginInProgress = false;
    loginCheckTimer?.cancel();

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('로그인 중 오류가 발생했습니다: ${error.description}'),
        backgroundColor: Colors.red,
        duration: const Duration(seconds: 3),
        action: SnackBarAction(
          label: '다시 시도',
          onPressed: () {
            _goToLoginPage();
          },
        ),
      ),
    );
  }

  // 로그인 페이지인지 확인
  bool _isLoginPage(String url) {
    return url.contains('/login') ||
        url.contains('login') && url.contains('jeongseongmkt.com') ||
        url.endsWith('login') ||
        url.contains('signin');
  }

  // 회원가입 페이지인지 확인
  bool _isSignupPage(String url) {
    return url.contains('/join') ||
        url.contains('/signup') ||
        url.contains('/register') ||
        url.contains('join') && url.contains('jeongseongmkt.com') ||
        url.contains('signup') && url.contains('jeongseongmkt.com') ||
        url.contains('register') && url.contains('jeongseongmkt.com') ||
        url.endsWith('join') ||
        url.endsWith('signup') ||
        url.endsWith('register');
  }

  // 리뷰어 회원가입 페이지인지 확인
  bool _isReviewerSignupPage(String url) {
    return url.contains('/join/reviewer') ||
        url.contains('reviewer') && url.contains('join') ||
        url.contains('reviewer') && url.contains('jeongseongmkt.com');
  }

  // 리뷰어 회원가입 성공 페이지인지 확인
  bool _isReviewerSignupSuccessPage(String url) {
    return url.contains('/join/reviewer/success') ||
        url.contains('/join/reviewer/complete') ||
        url.contains('reviewer') && url.contains('success') ||
        url.contains('reviewer') && url.contains('complete') ||
        url.contains('reviewer') && url.contains('welcome') ||
        url.contains('reviewer') && url.contains('thank');
  }

  // 사업자 회원가입 성공 페이지인지 확인
  bool _isSignupSuccessPage(String url) {
    return url.contains('/join/success') ||
        url.contains('/signup/success') ||
        url.contains('/register/success') ||
        url.contains('/join/complete') ||
        url.contains('/signup/complete') ||
        url.contains('/register/complete') ||
        url.contains('success') && url.contains('join') ||
        url.contains('complete') && url.contains('join') ||
        url.contains('welcome') && url.contains('jeongseongmkt.com') ||
        url.contains('thank') && url.contains('jeongseongmkt.com');
  }

  // 앱 내에서 처리해야 할 URL인지 확인
  bool _shouldHandleInApp(String url) {
    return url.contains('jeongseongmkt.com') ||
        url.contains('kakao') ||
        url.contains('naver') ||
        url.contains('google') ||
        url.contains('facebook');
  }

  // 로그인 체크 타이머 시작
  void _startLoginCheckTimer() {
    loginCheckTimer?.cancel();
    loginCheckTimer = Timer.periodic(const Duration(seconds: 3), (timer) {
      // 회원가입 진행 중이면 타임아웃 처리하지 않음
      if (isSignupInProgress) {
        return;
      }

      if (!isLoginInProgress && !isOAuthInProgress) {
        timer.cancel();
        return;
      }

      // 30초 후에도 로그인이 완료되지 않으면 타임아웃 처리
      if (timer.tick >= 10) {
        timer.cancel();
        isLoginInProgress = false;
        isOAuthInProgress = false;
        _handleLoginTimeout();
      }
    });
  }

  // 로그인 타임아웃 처리
  void _handleLoginTimeout() {
    debugPrint('로그인 타임아웃');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('로그인 시간이 초과되었습니다. 다시 시도해주세요.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
      ),
    );
    _redirectToMainPage();
  }

  // 로그인 완료 확인
  void _checkLoginCompletion(String url) {
    // 이미 리다이렉션 중이면 중복 처리 방지
    if (isRedirecting) {
      debugPrint('리다이렉션 중이므로 로그인 완료 처리 건너뜀');
      return;
    }

    // 로그인 페이지에서는 성공으로 인식하지 않음
    if (_isLoginPage(url)) {
      return;
    }

    if (_isLoginSuccess(url)) {
      isLoginInProgress = false;
      loginCheckTimer?.cancel();
      _redirectToMainPage();
    } else if (_isLoginFailed(url)) {
      isLoginInProgress = false;
      loginCheckTimer?.cancel();
      _handleLoginFailed();
    }
  }

  // 4. _handleUrlChange 메서드 수정
  void _handleUrlChange(String url) {
    if (lastUrl != url) {
      lastUrl = url;
      debugPrint('URL 변경: $url');

      // 네비게이션 히스토리 관리
      _updateNavigationHistory(url);

      // 이미 리다이렉션 중이면 추가 처리 방지
      if (isRedirecting) {
        debugPrint('리다이렉션 중이므로 URL 변경 처리 건너뜀');
        return;
      }

      // 회원가입 페이지에서 다른 페이지로 이동 시 회원가입 상태 초기화
      if (isSignupInProgress && !_isSignupPage(url)) {
        debugPrint('회원가입 페이지에서 벗어남: $url');
        isSignupInProgress = false;
      }

      // 사업자 회원가입 완료 후 성공 페이지 감지
      if (_isSignupSuccessPage(url)) {
        debugPrint('사업자 회원가입 완료 감지: $url');
        isSignupInProgress = false;
        isLoginInProgress = false;
        isOAuthInProgress = false;
        loginCheckTimer?.cancel();

        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('사업자 회원가입이 완료되었습니다!'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 3),
          ),
        );
      }

      // 리뷰어 회원가입 완료 후 성공 페이지 감지
      if (_isReviewerSignupSuccessPage(url)) {
        debugPrint('리뷰어 회원가입 완료 감지: $url');
        isSignupInProgress = false;
        isLoginInProgress = false;
        isOAuthInProgress = false;
        loginCheckTimer?.cancel();

        _showReviewerSignupCompleteDialog();
      }

      // 마이페이지 처리를 가장 먼저 수행
      if (_isMyPage(url)) {
        debugPrint('마이페이지로 이동: $url');
        // 마이페이지로 이동할 때는 모든 플래그 초기화
        isRedirecting = false;
        isLoginInProgress = false;
        isOAuthInProgress = false;
        isSignupInProgress = false;
        loginCheckTimer?.cancel();

        // 마이페이지 이동 메시지
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('마이페이지로 이동했습니다.'),
            backgroundColor: Colors.blue,
            duration: Duration(seconds: 2),
          ),
        );
        return; // 중요: 여기서 반드시 return
      }

      // 로그아웃 처리
      if (_isLogoutPage(url)) {
        _handleLogoutStart();
        return;
      }

      // OAuth 콜백 처리
      if (_isOAuthCallback(url)) {
        _handleOAuthCallback(url);
        return;
      }

      // 로그인 페이지에서는 성공으로 인식하지 않음
      if (_isLoginPage(url)) {
        return;
      }

      // 회원가입 페이지에서는 로그인 성공으로 인식하지 않음
      if (_isSignupPage(url)) {
        return;
      }

      // 로그인 완료 후 메인페이지로 강제 이동
      // 단, 마이페이지가 아닌 경우에만
      if (_isLoginSuccess(url) && !_isMyPage(url)) {
        _redirectToMainPage();
      }

      // 로그인 실패 감지
      if (_isLoginFailed(url)) {
        _handleLoginFailed();
      }
    }
  }

  // 마이페이지 URL 감지
  bool _isMyPage(String url) {
    // URL을 소문자로 변환하여 대소문자 구분 없이 체크
    final lowerUrl = url.toLowerCase();

    return lowerUrl.contains('/profile') ||
        lowerUrl.contains('/mypage') ||
        lowerUrl.contains('/my-page') ||
        lowerUrl.contains('/my_page') ||
        lowerUrl.contains('/account') ||
        lowerUrl.contains('/user') ||
        lowerUrl.contains('/member') ||
        lowerUrl.contains('/me') ||
        lowerUrl.contains('profile') &&
            lowerUrl.contains('jeongseongmkt.com') ||
        lowerUrl.contains('mypage') && lowerUrl.contains('jeongseongmkt.com') ||
        lowerUrl.contains('account') &&
            lowerUrl.contains('jeongseongmkt.com') ||
        lowerUrl.contains('member') && lowerUrl.contains('jeongseongmkt.com') ||
        // 추가 패턴들
        lowerUrl.contains('dashboard') && lowerUrl.contains('user') ||
        lowerUrl.contains('settings') &&
            lowerUrl.contains('jeongseongmkt.com') ||
        lowerUrl.contains('my-account') ||
        lowerUrl.contains('my_account') ||
        lowerUrl.contains('개인정보') ||
        lowerUrl.contains('회원정보');
  }

  // 로그인 리다이렉션 감지 (더 포괄적으로)
  bool _isLoginRedirect(String url) {
    return url.contains('login') ||
        url.contains('auth') ||
        url.contains('callback') ||
        url.contains('oauth') ||
        url.contains('kakao') ||
        url.contains('naver') ||
        url.contains('google') ||
        url.contains('facebook') ||
        url.contains('apple') ||
        url.contains('signin') ||
        url.contains('signup');
  }

  // 2. _isLoginSuccess 메서드 수정 - 마이페이지 체크를 먼저 수행
  bool _isLoginSuccess(String url) {
    // 마이페이지라면 로그인 성공으로 간주하지 않음
    if (_isMyPage(url)) {
      return false;
    }

    // 로그인 페이지는 제외
    if (_isLoginPage(url)) {
      return false;
    }

    // OAuth 콜백 URL 처리
    if (_isOAuthCallback(url)) {
      return true;
    }

    // 간편로그인 콜백 URL 처리
    if (url.contains('kakao') &&
        (url.contains('success') ||
            url.contains('token') ||
            url.contains('callback'))) {
      return true;
    }
    if (url.contains('naver') &&
        (url.contains('success') ||
            url.contains('token') ||
            url.contains('callback'))) {
      return true;
    }
    if (url.contains('google') &&
        (url.contains('success') ||
            url.contains('token') ||
            url.contains('callback'))) {
      return true;
    }

    // 특정 키워드가 포함된 경우만 성공으로 간주
    if (url.contains('success') ||
        url.contains('token') ||
        url.contains('access') ||
        url.contains('authorized') ||
        url.contains('verified')) {
      return true;
    }

    // jeongseongmkt.com 도메인이지만 로그인/마이페이지가 아닌 경우
    // 더 엄격한 조건 추가
    if (url.contains('jeongseongmkt.com') &&
        !url.contains('login') &&
        !url.contains('signin') &&
        !url.contains('signup') &&
        !url.contains('join') &&
        !url.contains('register') &&
        !url.contains('auth') &&
        !url.contains('callback') &&
        !_isMyPage(url)) {
      // 로그인 직후에만 true 반환하도록 수정
      return isLoginInProgress || isOAuthInProgress;
    }

    return false;
  }

  // 로그인 실패 감지 (더 포괄적으로)
  bool _isLoginFailed(String url) {
    return url.contains('error') ||
        url.contains('fail') ||
        url.contains('cancel') ||
        url.contains('denied') ||
        url.contains('unauthorized') ||
        url.contains('invalid') ||
        url.contains('expired');
  }

  // 메인페이지로 강제 리다이렉션
  void _redirectToMainPage() {
    // 이미 리다이렉션 중이면 중복 호출 방지
    if (isRedirecting) {
      debugPrint('이미 리다이렉션 중입니다. 중복 호출 방지');
      return;
    }

    debugPrint('메인페이지로 리다이렉션 중...');
    isRedirecting = true;
    isLoginInProgress = false;
    isOAuthInProgress = false;
    isLogoutInProgress = false;
    loginCheckTimer?.cancel();

    Future.delayed(const Duration(milliseconds: 1000), () {
      if (mounted) {
        setState(() {
          isLoading = true;
        });
        controller.loadRequest(Uri.parse(mainPageUrl));

        // 성공 메시지 표시
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('메인페이지로 이동합니다.'),
            backgroundColor: Colors.green,
            duration: Duration(seconds: 2),
          ),
        );

        // 리다이렉션 완료 후 상태 초기화
        Future.delayed(const Duration(seconds: 3), () {
          isRedirecting = false;
        });
      }
    });
  }

  // 로그인 리다이렉션 처리
  void _handleLoginRedirect(String url) {
    debugPrint('로그인 리다이렉션 처리: $url');
    setState(() {
      isLoading = true;
    });

    // 로그인 처리 중임을 표시
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('로그인 처리 중입니다...'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  // 로그인 실패 처리
  void _handleLoginFailed() {
    debugPrint('로그인 실패 감지');
    isLoginInProgress = false;
    isOAuthInProgress = false;
    loginCheckTimer?.cancel();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('로그인에 실패했습니다. 다시 시도해주세요.'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 3),
      ),
    );
  }

  // JavaScript 메시지 처리
  void _handleJavaScriptMessage(String message) {
    debugPrint('JavaScript 메시지: $message');

    // 이미 리다이렉션 중이면 중복 처리 방지
    if (isRedirecting &&
        (message.contains('login_success') ||
            message.contains('redirect_main'))) {
      debugPrint('리다이렉션 중이므로 JavaScript 메시지 처리 건너뜀: $message');
      return;
    }

    if (message.contains('login_success')) {
      _redirectToMainPage();
    } else if (message.contains('login_failed')) {
      _handleLoginFailed();
    } else if (message.contains('logout_success')) {
      _handleLogoutSuccess();
    } else if (message.contains('redirect_main')) {
      _redirectToMainPage();
    } else if (message.contains('mypage_clicked')) {
      _handleMyPageClick();
    } else if (message.contains('signup_clicked')) {
      _handleSignupClick();
    } else if (message.contains('signup_started')) {
      _handleSignupClick();
    } else if (message.contains('biz_signup_complete')) {
      _handleBizSignupComplete();
    } else if (message.contains('reviewer_signup_complete')) {
      _handleReviewerSignupComplete();
    } else if (message.contains('file_upload_missing')) {
      _handleFileUploadMissing();
    } else if (message.contains('file_upload_success')) {
      _handleFileUploadSuccess();
    } else if (message.contains('login_started')) {
      isLoginInProgress = true;
      _startLoginCheckTimer();
    } else if (message.contains('oauth_started')) {
      isOAuthInProgress = true;
      isLoginInProgress = true;
      _startLoginCheckTimer();
    } else if (message.contains('logout_started')) {
      isLogoutInProgress = true;
    } else if (message.contains('file_input_clicked')) {
      _handleFileInputClick();
    } else if (message.contains('file_upload_button_clicked')) {
      _handleFileUploadButtonClick();
    } else if (message.contains('file_selected:')) {
      _handleFileSelected(message);
    }
  }

  // 마이페이지 클릭 처리
  void _handleMyPageClick() {
    debugPrint('마이페이지 클릭 감지');

    // 마이페이지 클릭 시 메인페이지로 리다이렉션하지 않음
    // 웹사이트의 마이페이지로 정상 이동하도록 허용
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('마이페이지로 이동합니다.'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );

    // 마이페이지 URL로 직접 이동 (필요한 경우)
    // controller.loadRequest(Uri.parse('http://jeongseongmkt.com/mypage'));
  }

  // 회원가입 클릭 처리
  void _handleSignupClick() {
    debugPrint('회원가입 클릭 감지');

    // 회원가입 진행 상태 설정
    isSignupInProgress = true;
    isLoginInProgress = false;
    isOAuthInProgress = false;
    loginCheckTimer?.cancel();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('회원가입 페이지로 이동합니다.'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );

    // 회원가입 페이지로 이동
    controller.loadRequest(
      Uri.parse('https://www.jeongseongmkt.com/join/type'),
    );
  }

  // 사업자 회원가입 완료 처리
  void _handleBizSignupComplete() {
    debugPrint('사업자 회원가입 완료 버튼 클릭 감지');

    // 파일 업로드 상태 확인
    _checkFileUploadStatus();

    // 회원가입 진행 상태 초기화
    isSignupInProgress = false;
    isLoginInProgress = false;
    isOAuthInProgress = false;
    loginCheckTimer?.cancel();

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('사업자 회원가입이 진행 중입니다. 잠시만 기다려주세요.'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 3),
      ),
    );

    // 사업자 회원가입 완료 후에는 웹페이지의 기본 동작을 따르도록 함
    // 자동으로 리다이렉션하지 않음
  }

  // 리뷰어 회원가입 완료 처리
  void _handleReviewerSignupComplete() {
    debugPrint('리뷰어 회원가입 완료 버튼 클릭 감지');

    // 회원가입 진행 상태 초기화
    isSignupInProgress = false;
    isLoginInProgress = false;
    isOAuthInProgress = false;
    loginCheckTimer?.cancel();

    // 리뷰어 회원가입 완료 다이얼로그 표시
    _showReviewerSignupCompleteDialog();
  }

  // 파일 업로드 상태 확인
  Future<void> _checkFileUploadStatus() async {
    try {
      await controller.runJavaScript('''
        console.log('=== 파일 업로드 상태 확인 ===');
        const fileInputs = document.querySelectorAll('input[type="file"]');
        let hasFile = false;
        
        fileInputs.forEach(function(input, index) {
          if (input.files && input.files.length > 0) {
            console.log('파일 입력 요소 ' + index + '에 파일이 설정됨:', input.files[0].name, input.files[0].size);
            hasFile = true;
          } else {
            console.warn('파일 입력 요소 ' + index + '에 파일이 설정되지 않음');
          }
        });
        
        if (!hasFile) {
          console.error('사업자 등록증 파일이 업로드되지 않았습니다!');
          Flutter.postMessage('file_upload_missing');
        } else {
          console.log('파일 업로드 상태 정상');
          Flutter.postMessage('file_upload_success');
        }
      ''');
    } catch (e) {
      debugPrint('파일 업로드 상태 확인 오류: $e');
    }
  }

  // 파일 업로드 누락 처리
  void _handleFileUploadMissing() {
    debugPrint('사업자 등록증 파일 업로드 누락 감지');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('사업자 등록증 파일을 업로드해주세요. 파일 업로드는 필수입니다.'),
        backgroundColor: Colors.red,
        duration: Duration(seconds: 5),
      ),
    );
  }

  // 파일 업로드 성공 처리
  void _handleFileUploadSuccess() {
    debugPrint('사업자 등록증 파일 업로드 성공 확인');

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('사업자 등록증 파일이 성공적으로 업로드되었습니다.'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 3),
      ),
    );
  }

  // 리뷰어 회원가입 완료 다이얼로그 표시
  void _showReviewerSignupCompleteDialog() {
    showDialog(
      context: context,
      barrierDismissible: false, // 다이얼로그 외부 터치로 닫기 방지
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text(
            '회원가입 완료',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.green,
            ),
          ),
          content: const Text(
            '회원가입이 완료되었습니다.\n메인페이지로 이동합니다.',
            style: TextStyle(fontSize: 16, height: 1.5),
            textAlign: TextAlign.center,
          ),
          actions: [
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop(); // 다이얼로그 닫기
                _redirectToMainPage(); // 메인페이지로 이동
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                '확인',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        );
      },
    );
  }

  // 로그아웃 성공 처리
  void _handleLogoutSuccess() {
    debugPrint('로그아웃 성공');
    isLogoutInProgress = false;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('로그아웃이 완료되었습니다.'),
        backgroundColor: Colors.green,
        duration: Duration(seconds: 2),
      ),
    );

    _redirectToMainPage();
  }

  // 파일 입력 클릭 처리
  void _handleFileInputClick() {
    debugPrint('파일 입력 클릭됨');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('파일 선택 창이 열립니다.'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // 파일 업로드 버튼 클릭 처리
  void _handleFileUploadButtonClick() {
    debugPrint('파일 업로드 버튼 클릭됨');
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('파일 업로드 버튼이 클릭되었습니다.'),
        backgroundColor: Colors.blue,
        duration: Duration(seconds: 2),
      ),
    );
  }

  // 파일 선택 처리
  void _handleFileSelected(String message) {
    final fileName = message.split(':')[1];
    debugPrint('파일 선택됨: $fileName');
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('파일이 선택되었습니다: $fileName'),
        backgroundColor: Colors.green,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  // 파일 업로드 메시지 처리
  void _handleFileUploadMessage(String message) {
    debugPrint('파일 업로드 메시지: $message');

    if (message == 'request_file_picker') {
      _showFilePicker();
    } else if (message.startsWith('file_selected:')) {
      final fileName = message.split(':')[1];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('파일이 선택되었습니다: $fileName'),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 3),
        ),
      );
    }
  }

  // 파일 선택기 표시
  void _showFilePicker() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'pdf', 'doc', 'docx'],
        allowMultiple: false,
        withData: true, // 파일 데이터도 함께 가져오기
      );

      if (result != null) {
        PlatformFile file = result.files.first;
        debugPrint('선택된 파일: ${file.name}, 크기: ${file.size}');

        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('파일이 선택되었습니다: ${file.name}'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );

        // WebView에 실제 파일 데이터와 함께 전달
        await _injectFileToWebView(file);
      } else {
        debugPrint('파일 선택이 취소되었습니다.');
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('파일 선택이 취소되었습니다.'),
            backgroundColor: Colors.orange,
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      debugPrint('파일 선택기 오류: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('파일 선택 중 오류가 발생했습니다.'),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  // WebView에 파일 데이터 주입
  Future<void> _injectFileToWebView(PlatformFile file) async {
    try {
      // Base64로 파일 데이터 인코딩
      String base64Data = '';
      if (file.bytes != null) {
        base64Data = base64Encode(file.bytes!);
      }

      await controller.runJavaScript('''
        console.log('=== 파일 데이터 주입 시작 ===');
        const fileName = '${file.name}';
        const fileSize = ${file.size};
        const mimeType = '${_getMimeType(file.name)}';
        const base64Data = '${base64Data}';
        console.log('파일 정보:', fileName, '크기:', fileSize, '타입:', mimeType);
        
        // 1. 실제 파일 데이터를 웹페이지의 파일 입력 요소에 주입
        function injectFileData() {
          console.log('파일 데이터 주입 시작');
          
          const fileInputs = document.querySelectorAll('input[type="file"]');
          console.log('발견된 파일 입력 요소 개수:', fileInputs.length);
          
          fileInputs.forEach(function(input, index) {
            console.log('파일 입력 요소 ' + index + ' 처리 중:', input);
            
            try {
              // Base64를 Blob으로 변환
              const byteCharacters = atob(base64Data);
              const byteNumbers = new Array(byteCharacters.length);
              for (let i = 0; i < byteCharacters.length; i++) {
                byteNumbers[i] = byteCharacters.charCodeAt(i);
              }
              const byteArray = new Uint8Array(byteNumbers);
              const blob = new Blob([byteArray], { type: mimeType });
              
              // 실제 File 객체 생성
              const fileObject = new File([blob], fileName, {
                type: mimeType,
                lastModified: Date.now(),
                size: fileSize
              });
              
              // DataTransfer 객체 생성 및 파일 추가
              const dataTransfer = new DataTransfer();
              dataTransfer.items.add(fileObject);
              
              // input의 files 속성 설정
              try {
                input.files = dataTransfer.files;
                console.log('input.files 설정 완료:', input.files[0].name, '크기:', input.files[0].size, '타입:', input.files[0].type);
              } catch (e) {
                console.error('input.files 설정 실패 (직접 할당):', e);
                // 대체 방법: Object.defineProperty
                try {
                  Object.defineProperty(input, 'files', {
                    value: dataTransfer.files,
                    writable: false,
                    configurable: true
                  });
                  console.log('Object.defineProperty로 input.files 설정 완료:', input.files[0].name);
                } catch (e2) {
                  console.error('Object.defineProperty 대체 설정 실패:', e2);
                }
              }

              // input.value를 filename으로 설정 (일부 웹페이지에서 파일명 표시용으로 사용)
              input.value = 'C:\\\\fakepath\\\\' + fileName;
              console.log('input.value 설정:', input.value);
              
              // 다양한 이벤트 발생
              const events = ['change', 'input', 'focus', 'blur', 'mouseup', 'click'];
              events.forEach(eventName => {
                const event = new Event(eventName, { bubbles: true });
                input.dispatchEvent(event);
                console.log('이벤트 발생:', eventName);
              });
              
              // CustomEvent 발생 (웹페이지에서 커스텀 리스너가 있을 경우)
              const customEvent = new CustomEvent('fileSelected', {
                detail: { fileName: fileName, fileType: mimeType, fileSize: fileSize },
                bubbles: true
              });
              input.dispatchEvent(customEvent);
              console.log('CustomEvent 발생: fileSelected');
              
            } catch (e) {
              console.error('파일 데이터 주입 실패:', e);
            }
          });
        }
        
        // 2. 모든 가능한 텍스트 요소를 찾아서 강제로 파일명으로 교체
        function forceReplaceAllText() {
          console.log('전체 텍스트 교체 시작');
          
          // 모든 요소를 스캔
          const allElements = document.querySelectorAll('*');
          let replacedCount = 0;
          
          allElements.forEach(function(element) {
            // textContent 확인
            if (element.textContent) {
              const originalText = element.textContent;
              if (originalText.includes('선택된 파일 없음') || 
                  originalText.includes('파일을 선택하세요') ||
                  originalText.includes('No file selected') ||
                  originalText.includes('Choose file') ||
                  originalText.includes('파일 선택') ||
                  originalText.includes('찾기') ||
                  originalText.trim() === '' ||
                  originalText === 'null') {
                
                element.textContent = fileName;
                element.style.color = '#333';
                element.style.fontWeight = 'bold';
                element.style.display = 'block';
                console.log('텍스트 교체:', element.tagName, element.className, originalText, '->', fileName);
                replacedCount++;
              }
            }
            
            // value 속성 확인 (input 요소)
            if (element.value !== undefined) {
              const originalValue = element.value;
              if (originalValue.includes('선택된 파일 없음') || 
                  originalValue.includes('파일을 선택하세요') ||
                  originalValue.includes('No file selected') ||
                  originalValue.includes('Choose file') ||
                  originalValue.includes('파일 선택') ||
                  originalValue.includes('찾기') ||
                  originalValue.trim() === '' ||
                  originalValue === 'null') {
                
                element.value = fileName;
                element.style.color = '#333';
                element.style.fontWeight = 'bold';
                console.log('값 교체:', element.tagName, element.className, originalValue, '->', fileName);
                replacedCount++;
              }
            }
          });
          
          console.log('총 교체된 요소 개수:', replacedCount);
        }
        
        // 2. 파일 입력 요소 주변의 모든 요소 강제 업데이트
        function forceUpdateAroundFileInputs() {
          console.log('파일 입력 요소 주변 업데이트 시작');
          
          const fileInputs = document.querySelectorAll('input[type="file"]');
          fileInputs.forEach(function(input, index) {
            console.log('파일 입력 요소 ' + index + ' 주변 처리:', input);
            
            // 부모 요소부터 시작해서 모든 자식 요소 확인
            let parent = input.parentElement;
            while (parent) {
              const siblings = parent.querySelectorAll('*');
              siblings.forEach(function(sibling) {
                if (sibling !== input) {
                  const text = sibling.textContent || sibling.value || '';
                  if (text.includes('선택된 파일 없음') || text.includes('파일을 선택하세요')) {
                    sibling.textContent = fileName;
                    sibling.value = fileName;
                    sibling.style.color = '#333';
                    sibling.style.fontWeight = 'bold';
                    console.log('형제 요소 업데이트:', sibling.tagName, sibling.className, text, '->', fileName);
                  }
                }
              });
              parent = parent.parentElement;
            }
          });
        }
        
        // 3. 특정 패턴의 요소들 강제 생성/업데이트
        function createOrUpdateFileDisplayElements() {
          console.log('파일 표시 요소 생성/업데이트 시작');
          
          const fileInputs = document.querySelectorAll('input[type="file"]');
          fileInputs.forEach(function(input, index) {
            // 파일 입력 요소 다음에 파일명 표시 요소가 없으면 생성
            let nextSibling = input.nextElementSibling;
            let foundDisplayElement = false;
            
            // 다음 형제 요소들 확인
            while (nextSibling) {
              const text = nextSibling.textContent || nextSibling.value || '';
              if (text.includes(fileName) || text.includes('선택된 파일 없음') || text.includes('파일을 선택하세요')) {
                nextSibling.textContent = fileName;
                nextSibling.value = fileName;
                nextSibling.style.color = '#333';
                nextSibling.style.fontWeight = 'bold';
                foundDisplayElement = true;
                console.log('기존 표시 요소 업데이트:', nextSibling.tagName, nextSibling.className);
                break;
              }
              nextSibling = nextSibling.nextElementSibling;
            }
            
            // 표시 요소가 없으면 생성
            if (!foundDisplayElement) {
              const displayElement = document.createElement('span');
              displayElement.textContent = fileName;
              displayElement.style.color = '#333';
              displayElement.style.fontWeight = 'bold';
              displayElement.style.display = 'block';
              displayElement.style.marginLeft = '10px';
              displayElement.id = 'flutter-file-display-' + index;
              
              input.parentElement.insertBefore(displayElement, input.nextSibling);
              console.log('새 표시 요소 생성:', displayElement.id);
            }
          });
        }
        
        // 4. 모든 함수 실행 (파일 데이터 주입을 먼저 실행)
        injectFileData();
        forceReplaceAllText();
        forceUpdateAroundFileInputs();
        createOrUpdateFileDisplayElements();
        
        // 전역 함수도 호출
        if (typeof window.forceDisplayFileName === 'function') {
          window.forceDisplayFileName(fileName);
        }
        
        // 5. 지연 실행 (여러 번)
        setTimeout(function() { 
          console.log('지연 실행 1 (100ms)');
          injectFileData();
          forceReplaceAllText(); 
          if (typeof window.forceDisplayFileName === 'function') {
            window.forceDisplayFileName(fileName);
          }
        }, 100);
        
        setTimeout(function() { 
          console.log('지연 실행 2 (500ms)');
          injectFileData();
          forceReplaceAllText(); 
          forceUpdateAroundFileInputs(); 
          if (typeof window.forceDisplayFileName === 'function') {
            window.forceDisplayFileName(fileName);
          }
        }, 500);
        
        setTimeout(function() { 
          console.log('지연 실행 3 (1000ms)');
          injectFileData();
          forceReplaceAllText(); 
          createOrUpdateFileDisplayElements(); 
          if (typeof window.forceDisplayFileName === 'function') {
            window.forceDisplayFileName(fileName);
          }
        }, 1000);
        
        setTimeout(function() { 
          console.log('지연 실행 4 (2000ms)');
          injectFileData();
          forceReplaceAllText(); 
          if (typeof window.forceDisplayFileName === 'function') {
            window.forceDisplayFileName(fileName);
          }
        }, 2000);
        
        setTimeout(function() { 
          console.log('지연 실행 5 (3000ms)');
          injectFileData();
          forceReplaceAllText(); 
          if (typeof window.forceDisplayFileName === 'function') {
            window.forceDisplayFileName(fileName);
          }
        }, 3000);
        
        console.log('=== 파일 데이터 주입 및 표시 완료 ===');
        
        // 6. 파일 업로드 상태 확인 (추가 검증)
        setTimeout(function() {
          console.log('=== 파일 업로드 상태 확인 ===');
          const fileInputs = document.querySelectorAll('input[type="file"]');
          fileInputs.forEach(function(input, index) {
            if (input.files && input.files.length > 0) {
              console.log('파일 입력 요소 ' + index + '에 파일이 정상적으로 설정됨:', input.files[0].name, input.files[0].size);
            } else {
              console.warn('파일 입력 요소 ' + index + '에 파일이 설정되지 않음');
            }
          });
        }, 1000);
      ''');
    } catch (e) {
      debugPrint('파일 주입 오류: $e');
    }
  }

  // MIME 타입 결정
  String _getMimeType(String fileName) {
    String extension = fileName.split('.').last.toLowerCase();
    switch (extension) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'pdf':
        return 'application/pdf';
      case 'doc':
        return 'application/msword';
      case 'docx':
        return 'application/vnd.openxmlformats-officedocument.wordprocessingml.document';
      default:
        return 'application/octet-stream';
    }
  }

  // 파일 업로드 기능 활성화를 위한 JavaScript 주입
  void _injectFileUploadScript() {
    controller.runJavaScript('''
      console.log('파일 업로드 스크립트 주입 시작');
      
      // 파일 입력 요소 찾기 및 활성화
      function enableFileUploads() {
        const fileInputs = document.querySelectorAll('input[type="file"]');
        console.log('파일 입력 요소 개수:', fileInputs.length);
        
        fileInputs.forEach((input, index) => {
          console.log('파일 입력 요소 ' + index + ' 처리 중:', input);
          
          // 파일 입력 요소 활성화
          input.style.display = 'block';
          input.style.visibility = 'visible';
          input.disabled = false;
          input.removeAttribute('disabled');
          
          // 클릭 이벤트 추가 - Flutter 채널 사용
          input.addEventListener('click', function(e) {
            console.log('파일 입력 클릭됨:', e.target);
            FileUpload.postMessage('request_file_picker');
          });
          
          // 파일 선택 이벤트 추가
          input.addEventListener('change', function(e) {
            console.log('파일 선택됨:', e.target.files);
            if (e.target.files && e.target.files.length > 0) {
              FileUpload.postMessage('file_selected:' + e.target.files[0].name);
            }
          });
        });
        
        // 파일 업로드 버튼 찾기 및 활성화
        const uploadButtons = document.querySelectorAll('button[type="button"], .file-upload-btn, .upload-btn, [class*="upload"], [class*="file"], input[type="button"]');
        uploadButtons.forEach((button, index) => {
          const buttonText = button.textContent || button.innerText || button.value || '';
          if (buttonText.includes('파일') || buttonText.includes('업로드') || buttonText.includes('첨부') || 
              buttonText.includes('선택') || buttonText.includes('등록증') || buttonText.includes('사업자') ||
              buttonText.includes('찾기') || buttonText.includes('Browse') || buttonText.includes('Choose')) {
            console.log('파일 업로드 버튼 발견:', button);
            
            button.style.display = 'block';
            button.style.visibility = 'visible';
            button.disabled = false;
            button.removeAttribute('disabled');
            
            button.addEventListener('click', function(e) {
              console.log('파일 업로드 버튼 클릭됨:', e.target);
              FileUpload.postMessage('request_file_picker');
              
              // 파일 입력 요소 클릭 트리거
              const fileInput = document.querySelector('input[type="file"]');
              if (fileInput) {
                fileInput.click();
              }
            });
          }
        });
        
        // 모든 클릭 가능한 요소에 파일 업로드 감지 추가
        const allClickableElements = document.querySelectorAll('a, button, input, div[onclick], span[onclick]');
        allClickableElements.forEach((element) => {
          const text = element.textContent || element.innerText || element.value || '';
          if (text.includes('파일') || text.includes('업로드') || text.includes('첨부') || 
              text.includes('등록증') || text.includes('사업자') || text.includes('찾기')) {
            
            element.addEventListener('click', function(e) {
              console.log('파일 관련 요소 클릭됨:', e.target);
              FileUpload.postMessage('request_file_picker');
            });
          }
        });
        
        // 파일명 표시 요소 감지 및 모니터링
        function monitorFileNameElements() {
          const fileNameSelectors = [
            '.file-name', '.selected-file', '.upload-file-name', 
            '[class*="file-name"]', '[class*="selected"]', '[class*="upload"]',
            'span', 'div', 'p', 'label', 'input[type="text"]'
          ];
          
          fileNameSelectors.forEach(selector => {
            const elements = document.querySelectorAll(selector);
            elements.forEach(element => {
              const text = element.textContent || element.value || '';
              if (text.includes('선택된 파일 없음') || text.includes('파일을 선택하세요') || 
                  text.includes('No file selected') || text.includes('Choose file') ||
                  text.includes('파일 선택') || text.includes('찾기')) {
                console.log('파일명 표시 요소 발견:', element, text);
                
                // 파일 선택 시 업데이트할 수 있도록 마킹
                element.setAttribute('data-file-display', 'true');
              }
            });
          });
          
          // 추가적으로 모든 텍스트 요소 스캔
          const allTextElements = document.querySelectorAll('*');
          allTextElements.forEach(element => {
            const text = element.textContent || element.value || '';
            if (text.includes('선택된 파일 없음') || text.includes('파일을 선택하세요')) {
              console.log('추가 파일명 표시 요소 발견:', element, text);
              element.setAttribute('data-file-display', 'true');
            }
          });
        }
        
        // 파일명 강제 표시 함수 (Flutter에서 호출할 수 있도록 전역으로 등록)
        window.forceDisplayFileName = function(fileName) {
          console.log('전역 파일명 표시 함수 호출:', fileName);
          
          // 모든 요소를 스캔하여 강제로 파일명으로 교체
          const allElements = document.querySelectorAll('*');
          let replacedCount = 0;
          
          allElements.forEach(function(element) {
            // textContent 확인
            if (element.textContent) {
              const originalText = element.textContent;
              if (originalText.includes('선택된 파일 없음') || 
                  originalText.includes('파일을 선택하세요') ||
                  originalText.includes('No file selected') ||
                  originalText.includes('Choose file') ||
                  originalText.includes('파일 선택') ||
                  originalText.includes('찾기') ||
                  originalText.trim() === '' ||
                  originalText === 'null') {
                
                element.textContent = fileName;
                element.style.color = '#333';
                element.style.fontWeight = 'bold';
                element.style.display = 'block';
                console.log('전역 텍스트 교체:', element.tagName, element.className, originalText, '->', fileName);
                replacedCount++;
              }
            }
            
            // value 속성 확인 (input 요소)
            if (element.value !== undefined) {
              const originalValue = element.value;
              if (originalValue.includes('선택된 파일 없음') || 
                  originalValue.includes('파일을 선택하세요') ||
                  originalValue.includes('No file selected') ||
                  originalValue.includes('Choose file') ||
                  originalValue.includes('파일 선택') ||
                  originalValue.includes('찾기') ||
                  originalValue.trim() === '' ||
                  originalValue === 'null') {
                
                element.value = fileName;
                element.style.color = '#333';
                element.style.fontWeight = 'bold';
                console.log('전역 값 교체:', element.tagName, element.className, originalValue, '->', fileName);
                replacedCount++;
              }
            }
          });
          
          console.log('전역 함수로 총 교체된 요소 개수:', replacedCount);
        };
        
        // 파일명 표시 요소 모니터링 시작
        monitorFileNameElements();
        
        // 리뷰어 회원가입 완료 페이지 감지 및 처리
        function checkReviewerSignupComplete() {
          const currentUrl = window.location.href;
          const isReviewerSuccessPage = currentUrl.includes('/join/reviewer/success') ||
                                       currentUrl.includes('/join/reviewer/complete') ||
                                       currentUrl.includes('reviewer') && currentUrl.includes('success') ||
                                       currentUrl.includes('reviewer') && currentUrl.includes('complete') ||
                                       currentUrl.includes('reviewer') && currentUrl.includes('welcome') ||
                                       currentUrl.includes('reviewer') && currentUrl.includes('thank');
          
          if (isReviewerSuccessPage) {
            console.log('리뷰어 회원가입 완료 페이지 감지:', currentUrl);
            Flutter.postMessage('reviewer_signup_complete');
          }
        }
        
        // 페이지 로드 시 리뷰어 회원가입 완료 확인
        checkReviewerSignupComplete();
        
        // URL 변경 감지 (SPA에서 동적 라우팅 대응)
        let lastUrl = window.location.href;
        setInterval(function() {
          if (window.location.href !== lastUrl) {
            lastUrl = window.location.href;
            console.log('URL 변경 감지:', lastUrl);
            checkReviewerSignupComplete();
          }
        }, 1000);
      }
      
      // DOM이 로드된 후 실행
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', enableFileUploads);
      } else {
        enableFileUploads();
      }
      
      // 동적으로 추가되는 요소 감지
      const observer = new MutationObserver(function(mutations) {
        mutations.forEach(function(mutation) {
          if (mutation.type === 'childList') {
            mutation.addedNodes.forEach(function(node) {
              if (node.nodeType === 1) { // Element node
                const fileInputs = node.querySelectorAll ? 
                  node.querySelectorAll('input[type="file"]') : [];
                
                fileInputs.forEach(function(input) {
                  input.style.display = 'block';
                  input.style.visibility = 'visible';
                  input.disabled = false;
                  input.removeAttribute('disabled');
                });
                
                // 새로 추가된 파일명 표시 요소도 모니터링
                monitorFileNameElements();
              }
            });
          }
        });
      });
      
      // DOM 변경 감지 시작
      observer.observe(document.body, {
        childList: true,
        subtree: true
      });
      
      // 페이지 로드 완료 후 다시 한번 실행
      setTimeout(enableFileUploads, 1000);
    ''');
  }

  // 네비게이션 히스토리 관리
  void _updateNavigationHistory(String url) {
    // 중복 URL 방지
    if (navigationHistory.isEmpty || navigationHistory.last != url) {
      navigationHistory.add(url);
      debugPrint('히스토리 추가: $url (총 ${navigationHistory.length}개)');

      // 히스토리 크기 제한 (최대 50개)
      if (navigationHistory.length > 50) {
        navigationHistory.removeAt(0);
      }
    }
  }

  // 뒤로가기 가능 여부 확인
  bool _canGoBack() {
    return navigationHistory.length > 1;
  }

  // 이전 페이지로 이동
  void _goBack() {
    if (_canGoBack()) {
      // 현재 페이지 제거
      navigationHistory.removeLast();

      // 이전 페이지로 이동
      String previousUrl = navigationHistory.last;
      debugPrint('뒤로가기: $previousUrl');

      controller.loadRequest(Uri.parse(previousUrl));

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('이전 페이지로 이동합니다.'),
          backgroundColor: Colors.blue,
          duration: const Duration(seconds: 1),
        ),
      );
    } else {
      // 히스토리가 없으면 메인 페이지로
      debugPrint('히스토리가 없음, 메인 페이지로 이동');
      controller.loadRequest(Uri.parse(mainPageUrl));
    }
  }

  // 로그인 완료 감지를 위한 JavaScript 주입 (개선된 버전)
  void _injectLoginDetectionScript() {
    controller.runJavaScript('''
      // 로그인/로그아웃 상태 감지
      function checkLoginStatus() {
        // 현재 URL이 로그인 페이지인지 확인
        const currentUrl = window.location.href;
        const isLoginPage = currentUrl.includes('/login') || 
                           currentUrl.includes('login') && currentUrl.includes('jeongseongmkt.com') ||
                           currentUrl.endsWith('login');
        
        // 로그아웃 페이지 감지
        if (currentUrl.includes('/logout') || currentUrl.includes('logout')) {
          Flutter.postMessage('logout_started');
          return;
        }
        
        // OAuth 콜백 URL 감지
        if (currentUrl.includes('kakao') && (currentUrl.includes('code=') || currentUrl.includes('access_token='))) {
          Flutter.postMessage('oauth_started');
          return;
        }
        if (currentUrl.includes('naver') && (currentUrl.includes('code=') || currentUrl.includes('access_token='))) {
          Flutter.postMessage('oauth_started');
          return;
        }
        if (currentUrl.includes('google') && (currentUrl.includes('code=') || currentUrl.includes('access_token='))) {
          Flutter.postMessage('oauth_started');
          return;
        }
        
        // 로그인 페이지에서는 성공으로 인식하지 않음
        if (!isLoginPage) {
          // 마이페이지는 로그인 성공으로 인식하지 않음
          if (currentUrl.includes('/profile') || 
              currentUrl.includes('/mypage') || 
              currentUrl.includes('/account') ||
              (currentUrl.includes('profile') && currentUrl.includes('jeongseongmkt.com')) ||
              (currentUrl.includes('mypage') && currentUrl.includes('jeongseongmkt.com')) ||
              (currentUrl.includes('account') && currentUrl.includes('jeongseongmkt.com'))) {
            return;
          }
          
          // URL에서 로그인 성공 여부 확인
          if (currentUrl.includes('success') || 
              currentUrl.includes('token') ||
              currentUrl.includes('access') ||
              currentUrl.includes('authorized')) {
            Flutter.postMessage('login_success');
            return; // 중복 메시지 방지
          }
          
          // 간편로그인 콜백 URL 감지
          if ((currentUrl.includes('kakao') || currentUrl.includes('naver') || currentUrl.includes('google')) &&
              (currentUrl.includes('success') || currentUrl.includes('token') || currentUrl.includes('callback'))) {
            Flutter.postMessage('login_success');
            return; // 중복 메시지 방지
          }
        }
        
                  // 로그인/로그아웃/마이페이지 버튼 클릭 감지
          document.addEventListener('click', function(e) {
            const target = e.target;
            const text = target.textContent || '';
            const className = target.className || '';
            const id = target.id || '';
            const href = target.href || '';
            const onclick = target.getAttribute('onclick') || '';
            
            // 마이페이지 버튼 감지
            if (text.includes('마이페이지') || 
                text.includes('My Page') ||
                text.includes('Profile') ||
                text.includes('마이') ||
                href.includes('profile') ||
                href.includes('mypage') ||
                onclick.includes('profile') ||
                onclick.includes('mypage') ||
                target.closest('[data-profile]') ||
                target.closest('.profile-btn') ||
                target.closest('#profile-btn') ||
                target.closest('.mypage-btn') ||
                target.closest('#mypage-btn') ||
                target.closest('.profile') ||
                target.closest('.mypage') ||
                target.closest('[onclick*="profile"]') ||
                target.closest('[onclick*="mypage"]') ||
                target.closest('a[href*="profile"]') ||
                target.closest('a[href*="mypage"]')) {
              Flutter.postMessage('mypage_clicked');
              console.log('마이페이지 버튼 클릭 감지:', text, className, id, href, onclick);
              
              // 마이페이지 버튼 클릭 시 기본 동작 허용 (링크 이동)
              // e.preventDefault()를 호출하지 않음으로써 웹사이트의 링크가 정상 작동하도록 함
            }
            
            // 로그아웃 버튼 (더 포괄적으로 감지)
            if (text.includes('로그아웃') || 
                text.includes('Logout') ||
                text.includes('Sign out') ||
                text.includes('Sign-out') ||
                text.includes('Log out') ||
                text.includes('로그아웃') ||
                href.includes('logout') ||
                onclick.includes('logout') ||
                target.closest('[data-logout]') ||
                target.closest('.logout-btn') ||
                target.closest('#logout-btn') ||
                target.closest('.logout') ||
                target.closest('[onclick*="logout"]') ||
                target.closest('a[href*="logout"]')) {
              Flutter.postMessage('logout_started');
              console.log('로그아웃 버튼 클릭 감지:', text, className, id, href, onclick);
            }
            
            // 일반 로그인 버튼
            if (text.includes('로그인') || 
                text.includes('Login') ||
                text.includes('Sign in') ||
                target.closest('[data-login]') ||
                target.closest('.login-btn') ||
                target.closest('#login-btn')) {
              Flutter.postMessage('login_started');
            }
            
            // 회원가입 버튼 감지 (사업자 회원가입 페이지에서는 제외)
            const currentUrl = window.location.href;
            const isBizJoinPage = currentUrl.includes('/join/biz') || currentUrl.includes('biz');
            
            if ((text.includes('회원가입') || 
                text.includes('가입') ||
                text.includes('Sign Up') ||
                text.includes('Signup') ||
                text.includes('Register') ||
                text.includes('Join') ||
                className.includes('signup') ||
                className.includes('register') ||
                className.includes('join') ||
                id.includes('signup') ||
                id.includes('register') ||
                id.includes('join') ||
                href.includes('signup') ||
                href.includes('register') ||
                href.includes('join') ||
                onclick.includes('signup') ||
                onclick.includes('register') ||
                onclick.includes('join') ||
                target.closest('.signup-btn') ||
                target.closest('#signup-btn') ||
                target.closest('.register-btn') ||
                target.closest('#register-btn') ||
                target.closest('.join-btn') ||
                target.closest('#join-btn') ||
                target.closest('[data-signup]') ||
                target.closest('[data-register]') ||
                target.closest('[data-join]')) && !isBizJoinPage) {
              
              Flutter.postMessage('signup_started');
              console.log('회원가입 버튼 클릭 감지:', text, className, id, href, onclick);
              
              // 회원가입 페이지로 이동 (사업자 회원가입 페이지가 아닌 경우에만)
              e.preventDefault();
              window.location.href = 'https://www.jeongseongmkt.com/join/type';
            }
            
            // 사업자 회원가입 페이지에서의 회원가입 완료 버튼 감지
            if (isBizJoinPage && (text.includes('회원가입') || text.includes('가입') || text.includes('등록'))) {
              console.log('사업자 회원가입 완료 버튼 클릭 감지:', text, className, id);
              Flutter.postMessage('biz_signup_complete');
            }
            
            // 리뷰어 회원가입 페이지에서의 회원가입 완료 버튼 감지
            const isReviewerJoinPage = currentUrl.includes('/join/reviewer') || currentUrl.includes('reviewer');
            if (isReviewerJoinPage && (text.includes('회원가입') || text.includes('가입') || text.includes('등록'))) {
              console.log('리뷰어 회원가입 완료 버튼 클릭 감지:', text, className, id);
              Flutter.postMessage('reviewer_signup_complete');
            }
            
            // 간편로그인 버튼
            if (text.includes('카카오') || 
                text.includes('Kakao') ||
                text.includes('네이버') ||
                text.includes('Naver') ||
                text.includes('구글') ||
                text.includes('Google') ||
                className.includes('kakao') ||
                className.includes('naver') ||
                className.includes('google') ||
                id.includes('kakao') ||
                id.includes('naver') ||
                id.includes('google') ||
                target.closest('.kakao-login') ||
                target.closest('.naver-login') ||
                target.closest('.google-login') ||
                target.closest('[data-provider="kakao"]') ||
                target.closest('[data-provider="naver"]') ||
                target.closest('[data-provider="google"]')) {
              Flutter.postMessage('oauth_started');
              console.log('간편로그인 버튼 클릭 감지:', text, className, id);
            }
          });
        
        // 폼 제출 감지
        document.addEventListener('submit', function(e) {
          if (e.target.action && e.target.action.includes('login')) {
            Flutter.postMessage('login_started');
          }
          if (e.target.action && e.target.action.includes('logout')) {
            Flutter.postMessage('logout_started');
          }
        });
        
        // 새창 열림 감지 (간편로그인용)
        const originalOpen = window.open;
        window.open = function(url, name, features) {
          console.log('새창 열림 감지:', url);
          if (url && (url.includes('kakao') || url.includes('naver') || url.includes('google'))) {
            Flutter.postMessage('oauth_started');
          }
          return originalOpen.call(this, url, name, features);
        };
        
        // 페이지 변경 감지 (더 정확한 감지)
        let urlCheckInterval = setInterval(function() {
          const newUrl = window.location.href;
          if (newUrl !== currentUrl) {
            console.log('URL 변경 감지:', newUrl);
            
            // 로그아웃 완료 감지
            if (newUrl.includes('logout') || newUrl.includes('signout')) {
              Flutter.postMessage('logout_started');
              return;
            }
            
            // OAuth 콜백 URL 감지
            if (newUrl.includes('kakao') && (newUrl.includes('code=') || newUrl.includes('access_token='))) {
              Flutter.postMessage('oauth_started');
              return;
            }
            if (newUrl.includes('naver') && (newUrl.includes('code=') || newUrl.includes('access_token='))) {
              Flutter.postMessage('oauth_started');
              return;
            }
            if (newUrl.includes('google') && (newUrl.includes('code=') || newUrl.includes('access_token='))) {
              Flutter.postMessage('oauth_started');
              return;
            }
            
            // 로그인 페이지가 아닌 경우에만 성공으로 인식 (중복 방지)
            if (!newUrl.includes('/login') && 
                (newUrl.includes('success') || 
                 newUrl.includes('main') ||
                 newUrl.includes('dashboard') ||
                 newUrl.includes('home') ||
                 newUrl.includes('token') ||
                 newUrl.includes('callback'))) {
              Flutter.postMessage('redirect_main');
              return; // 중복 메시지 방지
            }
          }
        }, 500);
        
        // 페이지 언로드 시 인터벌 정리
        window.addEventListener('beforeunload', function() {
          clearInterval(urlCheckInterval);
        });
        
        // 로그인 상태 확인 (쿠키나 로컬스토리지)
        function checkLoginState() {
          // 쿠키에서 로그인 상태 확인
          const cookies = document.cookie.split(';');
          for (let cookie of cookies) {
            if (cookie.includes('token') || cookie.includes('auth') || cookie.includes('login')) {
              Flutter.postMessage('login_success');
              break;
            }
          }
          
          // 로컬스토리지에서 로그인 상태 확인
          if (localStorage.getItem('token') || localStorage.getItem('auth') || localStorage.getItem('login')) {
            Flutter.postMessage('login_success');
          }
        }
        
        // 페이지 로드 후 로그인 상태 확인
        setTimeout(checkLoginState, 1000);
        
        // MutationObserver를 사용하여 동적으로 추가되는 로그아웃 버튼 감지
        const observer = new MutationObserver(function(mutations) {
          mutations.forEach(function(mutation) {
            if (mutation.type === 'childList') {
              mutation.addedNodes.forEach(function(node) {
                if (node.nodeType === 1) { // Element node
                  const logoutElements = node.querySelectorAll ? 
                    node.querySelectorAll('[href*="logout"], [onclick*="logout"], .logout, .logout-btn, [data-logout]') : [];
                  
                  logoutElements.forEach(function(element) {
                    element.addEventListener('click', function() {
                      Flutter.postMessage('logout_started');
                      console.log('동적 로그아웃 버튼 클릭 감지');
                    });
                  });
                }
              });
            }
          });
        });
        
        // DOM 변경 감지 시작
        observer.observe(document.body, {
          childList: true,
          subtree: true
        });
      }
      
      // DOM이 로드된 후 실행
      if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', checkLoginStatus);
      } else {
        checkLoginStatus();
      }
    ''');
  }

  // 강제 리로드
  void _forceReload() {
    setState(() {
      isLoading = true;
    });
    retryCount = 0;
    controller.reload();
  }

  // 메인페이지로 이동
  void _goToMainPage() {
    setState(() {
      isLoading = true;
    });
    retryCount = 0;
    controller.loadRequest(Uri.parse(mainPageUrl));
  }

  // 로그인 페이지로 이동
  void _goToLoginPage() {
    setState(() {
      isLoading = true;
    });
    retryCount = 0;
    controller.loadRequest(Uri.parse('http://jeongseongmkt.com/login'));
  }

  // 로그아웃 페이지로 이동
  void _goToLogoutPage() {
    setState(() {
      isLoading = true;
    });
    retryCount = 0;
    controller.loadRequest(Uri.parse('http://jeongseongmkt.com/logout'));
  }

  void _debugPrintUrlInfo(String url) {
    debugPrint('=== URL 정보 ===');
    debugPrint('URL: $url');
    debugPrint('마이페이지인가? ${_isMyPage(url)}');
    debugPrint('로그인 성공인가? ${_isLoginSuccess(url)}');
    debugPrint('로그인 페이지인가? ${_isLoginPage(url)}');
    debugPrint('로그인 진행 중? $isLoginInProgress');
    debugPrint('OAuth 진행 중? $isOAuthInProgress');
    debugPrint('리다이렉션 중? $isRedirecting');
    debugPrint('================');
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false, // 기본 뒤로가기 동작 비활성화
      onPopInvoked: (didPop) {
        if (!didPop) {
          // 뒤로가기 처리
          _goBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            '정성마케팅',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
          ),
          backgroundColor: Colors.blue,
          foregroundColor: Colors.white,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () {
              _goBack();
            },
            tooltip: '뒤로가기',
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () {
                _forceReload();
              },
              tooltip: '새로고침',
            ),
            IconButton(
              icon: const Icon(Icons.home),
              onPressed: () {
                _goToMainPage();
              },
              tooltip: '홈으로',
            ),
            IconButton(
              icon: const Icon(Icons.login),
              onPressed: () {
                _goToLoginPage();
              },
              tooltip: '로그인',
            ),
            IconButton(
              icon: const Icon(Icons.logout),
              onPressed: () {
                _goToLogoutPage();
              },
              tooltip: '로그아웃',
            ),
          ],
        ),
        body: Stack(
          children: [
            WebViewWidget(controller: controller),
            if (isLoading)
              Container(
                color: Colors.white.withOpacity(0.9),
                child: const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 16),
                      Text('페이지를 로딩 중입니다...', style: TextStyle(fontSize: 16)),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
