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

  @override
  void initState() {
    super.initState();
    controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..addJavaScriptChannel(
        'Flutter',
        onMessageReceived: (JavaScriptMessage message) {
          _handleJavaScriptMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onProgress: (int progress) {
            // 로딩 진행률 업데이트
            debugPrint('로딩 진행률: $progress%');
          },
          onPageStarted: (String url) {
            setState(() {
              isLoading = true;
            });
            debugPrint('페이지 시작: $url');

            // 로그인 진행 중인지 확인 (로그인 페이지 자체는 제외)
            if (_isLoginRedirect(url) && !_isLoginPage(url)) {
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

            // 로그인 완료 감지를 위한 JavaScript 주입
            _injectLoginDetectionScript();

            // 로그인 진행 중이었다면 체크
            if (isLoginInProgress) {
              _checkLoginCompletion(url);
            }
          },
          onNavigationRequest: (NavigationRequest request) {
            debugPrint('네비게이션 요청: ${request.url}');

            // 로그인 페이지로의 이동은 허용
            if (_isLoginPage(request.url)) {
              return NavigationDecision.navigate;
            }

            // 로그인 완료 후 리다이렉션 처리
            if (_isLoginRedirect(request.url) && !_isLoginPage(request.url)) {
              _handleLoginRedirect(request.url);
              return NavigationDecision.navigate; // 로그인 페이지로 이동 허용
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
          },
        ),
      )
      ..loadRequest(Uri.parse(mainPageUrl));
  }

  @override
  void dispose() {
    loginCheckTimer?.cancel();
    super.dispose();
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
      if (!isLoginInProgress) {
        timer.cancel();
        return;
      }

      // 30초 후에도 로그인이 완료되지 않으면 타임아웃 처리
      if (timer.tick >= 10) {
        timer.cancel();
        isLoginInProgress = false;
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

  // URL 변경 감지 및 처리
  void _handleUrlChange(String url) {
    if (lastUrl != url) {
      lastUrl = url;
      debugPrint('URL 변경: $url');

      // 로그인 페이지에서는 성공으로 인식하지 않음
      if (_isLoginPage(url)) {
        return;
      }

      // 로그인 완료 후 메인페이지로 강제 이동
      if (_isLoginSuccess(url)) {
        _redirectToMainPage();
      }

      // 로그인 실패 감지
      if (_isLoginFailed(url)) {
        _handleLoginFailed();
      }
    }
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

  // 로그인 성공 감지 (더 정확하게)
  bool _isLoginSuccess(String url) {
    // 로그인 페이지는 제외
    if (_isLoginPage(url)) {
      return false;
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

    return url.contains('success') ||
        url.contains('main') ||
        url.contains('dashboard') ||
        url.contains('home') ||
        url.contains('welcome') ||
        url.contains('complete') ||
        url.contains('token') ||
        url.contains('access') ||
        url.contains('authorized') ||
        url.contains('verified') ||
        url.contains('profile') ||
        url.contains('account') ||
        // 메인페이지 도메인으로 돌아온 경우 (로그인 페이지 제외)
        (url.contains('jeongseongmkt.com') &&
            !url.contains('login') &&
            !url.contains('signin') &&
            !url.contains('signup') &&
            !url.contains('auth') &&
            !url.contains('callback'));
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
    debugPrint('메인페이지로 리다이렉션 중...');
    isLoginInProgress = false;
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

    if (message.contains('login_success')) {
      _redirectToMainPage();
    } else if (message.contains('login_failed')) {
      _handleLoginFailed();
    } else if (message.contains('redirect_main')) {
      _redirectToMainPage();
    } else if (message.contains('login_started')) {
      isLoginInProgress = true;
      _startLoginCheckTimer();
    }
  }

  // 로그인 완료 감지를 위한 JavaScript 주입 (개선된 버전)
  void _injectLoginDetectionScript() {
    controller.runJavaScript('''
      // 로그인 상태 감지
      function checkLoginStatus() {
        // 현재 URL이 로그인 페이지인지 확인
        const currentUrl = window.location.href;
        const isLoginPage = currentUrl.includes('/login') || 
                           currentUrl.includes('login') && currentUrl.includes('jeongseongmkt.com') ||
                           currentUrl.endsWith('login');
        
        // 로그인 페이지에서는 성공으로 인식하지 않음
        if (!isLoginPage) {
          // URL에서 로그인 성공 여부 확인
          if (currentUrl.includes('success') || 
              currentUrl.includes('token') ||
              currentUrl.includes('access') ||
              currentUrl.includes('authorized')) {
            Flutter.postMessage('login_success');
          }
          
          // 간편로그인 콜백 URL 감지
          if ((currentUrl.includes('kakao') || currentUrl.includes('naver') || currentUrl.includes('google')) &&
              (currentUrl.includes('success') || currentUrl.includes('token') || currentUrl.includes('callback'))) {
            Flutter.postMessage('login_success');
          }
        }
        
        // 로그인 버튼 클릭 감지 (간편로그인 포함)
        document.addEventListener('click', function(e) {
          const target = e.target;
          const text = target.textContent || '';
          const className = target.className || '';
          const id = target.id || '';
          
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
            Flutter.postMessage('login_started');
            console.log('간편로그인 버튼 클릭 감지:', text, className, id);
          }
        });
        
        // 폼 제출 감지
        document.addEventListener('submit', function(e) {
          if (e.target.action && e.target.action.includes('login')) {
            Flutter.postMessage('login_started');
          }
        });
        
        // 새창 열림 감지 (간편로그인용)
        const originalOpen = window.open;
        window.open = function(url, name, features) {
          console.log('새창 열림 감지:', url);
          if (url && (url.includes('kakao') || url.includes('naver') || url.includes('google'))) {
            Flutter.postMessage('login_started');
          }
          return originalOpen.call(this, url, name, features);
        };
        
        // 페이지 변경 감지 (더 정확한 감지)
        let urlCheckInterval = setInterval(function() {
          const newUrl = window.location.href;
          if (newUrl !== currentUrl) {
            console.log('URL 변경 감지:', newUrl);
            
            // 로그인 페이지가 아닌 경우에만 성공으로 인식
            if (!newUrl.includes('/login') && 
                (newUrl.includes('success') || 
                 newUrl.includes('main') ||
                 newUrl.includes('dashboard') ||
                 newUrl.includes('home') ||
                 newUrl.includes('token') ||
                 newUrl.includes('callback'))) {
              Flutter.postMessage('redirect_main');
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
    controller.reload();
  }

  // 메인페이지로 이동
  void _goToMainPage() {
    setState(() {
      isLoading = true;
    });
    controller.loadRequest(Uri.parse(mainPageUrl));
  }

  // 로그인 페이지로 이동
  void _goToLoginPage() {
    setState(() {
      isLoading = true;
    });
    controller.loadRequest(Uri.parse('http://jeongseongmkt.com/login'));
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
