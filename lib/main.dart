import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'dart:async';

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
  bool isRedirecting = false;
  int retryCount = 0;
  static const int maxRetries = 3;

  @override
  void initState() {
    super.initState();
    _initializeWebView();
  }

  void _initializeWebView() {
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.white)
      ..enableZoom(false)
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
        url.contains('signin') ||
        url.contains('signup');
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

      // 이미 리다이렉션 중이면 추가 처리 방지
      if (isRedirecting) {
        debugPrint('리다이렉션 중이므로 URL 변경 처리 건너뜀');
        return;
      }

      // 마이페이지 처리를 가장 먼저 수행
      if (_isMyPage(url)) {
        debugPrint('마이페이지로 이동: $url');
        // 마이페이지로 이동할 때는 모든 플래그 초기화
        isRedirecting = false;
        isLoginInProgress = false;
        isOAuthInProgress = false;
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
    } else if (message.contains('login_started')) {
      isLoginInProgress = true;
      _startLoginCheckTimer();
    } else if (message.contains('oauth_started')) {
      isOAuthInProgress = true;
      isLoginInProgress = true;
      _startLoginCheckTimer();
    } else if (message.contains('logout_started')) {
      isLogoutInProgress = true;
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
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          '정성마케팅',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white),
        ),
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
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
    );
  }
}
