//
//  NYTPhotosViewController.m
//  NYTPhotoViewer
//
//  Created by Brian Capps on 2/10/15.
//  Copyright (c) 2015 NYTimes. All rights reserved.
//

#import "NYTPhotosViewController.h"
#import "NYTPhotosViewControllerDataSource.h"
#import "NYTPhotosDataSource.h"
#import "NYTPhotoViewController.h"
#import "NYTPhotoTransitionController.h"
#import "NYTScalingImageView.h"
#import "NYTPhoto.h"
#import "NYTPhotosOverlayView.h"
#import "NYTPhotoCaptionView.h"
#import "NSBundle+NYTPhotoViewer.h"
#import <sys/utsname.h>
@import Photos;

#ifdef ANIMATED_GIF_SUPPORT
#import <FLAnimatedImage/FLAnimatedImage.h>
#endif

NSString * const NYTPhotosViewControllerDidNavigateToPhotoNotification = @"NYTPhotosViewControllerDidNavigateToPhotoNotification";
NSString * const NYTPhotosViewControllerWillDismissNotification = @"NYTPhotosViewControllerWillDismissNotification";
NSString * const NYTPhotosViewControllerDidDismissNotification = @"NYTPhotosViewControllerDidDismissNotification";

static const CGFloat NYTPhotosViewControllerOverlayAnimationDuration = 0.2;
static const CGFloat NYTPhotosViewControllerInterPhotoSpacing = 16.0;
static const UIEdgeInsets NYTPhotosViewControllerCloseButtonImageInsets = {3, 0, -3, 0};

@interface NYTPhotosViewController () <UIPageViewControllerDataSource, UIPageViewControllerDelegate, NYTPhotoViewControllerDelegate>

- (instancetype)initWithCoder:(NSCoder *)aDecoder NS_DESIGNATED_INITIALIZER;

@property (nonatomic) id <NYTPhotosViewControllerDataSource> dataSource;
@property (nonatomic) UIPageViewController *pageViewController;
@property (nonatomic) NYTPhotoTransitionController *transitionController;
@property (nonatomic) UIPopoverController *activityPopoverController;

@property (nonatomic) UIPanGestureRecognizer *panGestureRecognizer;
@property (nonatomic) UITapGestureRecognizer *singleTapGestureRecognizer;

@property (nonatomic) NYTPhotosOverlayView *overlayView;

/// A custom notification center to scope internal notifications to this `NYTPhotosViewController` instance.
@property (nonatomic) NSNotificationCenter *notificationCenter;

@property (nonatomic) BOOL shouldHandleLongPress;
@property (nonatomic) BOOL overlayWasHiddenBeforeTransition;

@property (nonatomic, readonly) NYTPhotoViewController *currentPhotoViewController;
@property (nonatomic, readonly) UIView *referenceViewForCurrentPhoto;
@property (nonatomic, readonly) CGPoint boundsCenterPoint;
@property (nonatomic) BOOL allowHideStatusBar;

@end

@implementation NYTPhotosViewController

#pragma mark - NSObject

- (void)dealloc {
    _pageViewController.dataSource = nil;
    _pageViewController.delegate = nil;
}

#pragma mark - NSObject(UIResponderStandardEditActions)

- (void)copy:(id)sender {
    if (self.currentlyDisplayedPhoto.image) {
        [[UIPasteboard generalPasteboard] setImage:self.currentlyDisplayedPhoto.image];
    }
}

// custom method
- (void)saveImage:(id)sender {
    if (self.currentlyDisplayedPhoto.image) {
        if ([PHPhotoLibrary authorizationStatus] == PHAuthorizationStatusAuthorized) {
            UIImageWriteToSavedPhotosAlbum(self.currentlyDisplayedPhoto.image, self, nil, nil);
        } else {
            [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([PHPhotoLibrary authorizationStatus] == PHAuthorizationStatusAuthorized) {
                        UIImageWriteToSavedPhotosAlbum(self.currentlyDisplayedPhoto.image, self, nil, nil);
                    } else {
                        // Display message to user
                        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Photo Library Access" message:@"Please enable Photo 'Read and Write' Access in System Settings" preferredStyle:UIAlertControllerStyleAlert];
                        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                        [self presentViewController:alert animated:YES completion:nil];
                    }
                });
           }];
        }
   }
}

#pragma mark - UIResponder

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)canPerformAction:(SEL)action withSender:(id)sender {
    if (self.shouldHandleLongPress &&
        (action == @selector(copy:) || @selector(saveImage:) == action) &&
        self.currentlyDisplayedPhoto.image &&
        !self.currentlyDisplayedPhoto.moviePlayerView) {
        return YES;
    }
    
    return NO;
}

#pragma mark - UIViewController

- (instancetype)initWithNibName:(NSString *)nibNameOrNil bundle:(NSBundle *)nibBundleOrNil {
    return [self initWithPhotos:nil];
}

- (instancetype)initWithCoder:(NSCoder *)aDecoder {
    self = [super initWithCoder:aDecoder];

    if (self) {
        [self commonInitWithPhotos:nil initialPhoto:nil delegate:nil];
    }

    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    self.allowHideStatusBar = [self checkValidDeviceModel];
    self.view.tintColor = [UIColor whiteColor];
    self.view.backgroundColor = [UIColor blackColor];
    self.pageViewController.view.backgroundColor = [UIColor clearColor];

    [self.pageViewController.view addGestureRecognizer:self.panGestureRecognizer];
    [self.pageViewController.view addGestureRecognizer:self.singleTapGestureRecognizer];
    
    [self addChildViewController:self.pageViewController];
    [self.view addSubview:self.pageViewController.view];
    [self.pageViewController didMoveToParentViewController:self];
    
    [self addOverlayView];

    self.transitionController.startingView = self.referenceViewForCurrentPhoto;
    
    UIView *endingView;
    if (self.currentlyDisplayedPhoto.image || self.currentlyDisplayedPhoto.placeholderImage) {
        endingView = self.currentPhotoViewController.scalingImageView.imageView;
    }
    
    self.transitionController.endingView = endingView;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    
    if (!self.overlayWasHiddenBeforeTransition) {
        [self setOverlayViewHidden:NO animated:YES];
    }
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    
    self.pageViewController.view.frame = self.view.bounds;
    self.overlayView.frame = self.view.bounds;
}

- (BOOL)prefersStatusBarHidden {
    // on iOS 9 and early iphone/ipad models hiding the status bar causes device rotation to be slow or
    // crashes the device. For the older models we will just show the status bar always.
    return ([[UIDevice currentDevice].systemVersion intValue] >= 10 && [self allowHideStatusBar]);
}

- (UIStatusBarAnimation)preferredStatusBarUpdateAnimation {
    return UIStatusBarAnimationFade;
}

- (void)dismissViewControllerAnimated:(BOOL)animated completion:(void (^)(void))completion {
    [self dismissViewControllerAnimated:animated userInitiated:NO completion:completion];
}

#pragma mark - NYTPhotosViewController

- (instancetype)initWithPhotos:(NSArray *)photos {
    return [self initWithPhotos:photos initialPhoto:photos.firstObject delegate:nil];
}

- (instancetype)initWithPhotos:(NSArray *)photos initialPhoto:(id <NYTPhoto>)initialPhoto {
    return [self initWithPhotos:photos initialPhoto:initialPhoto delegate:nil];
}

- (instancetype)initWithPhotos:(NSArray *)photos initialPhoto:(id <NYTPhoto>)initialPhoto delegate:(id<NYTPhotosViewControllerDelegate>)delegate {
    self = [super initWithNibName:nil bundle:nil];
    
    if (self) {
        [self commonInitWithPhotos:photos initialPhoto:initialPhoto delegate:delegate];
    }
    
    return self;
}

- (void)commonInitWithPhotos:(NSArray *)photos initialPhoto:(id <NYTPhoto>)initialPhoto delegate:(id<NYTPhotosViewControllerDelegate>)delegate {
    _dataSource = [[NYTPhotosDataSource alloc] initWithPhotos:photos];
    _delegate = delegate;

    _panGestureRecognizer = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(didPanWithGestureRecognizer:)];
    _singleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(didSingleTapWithGestureRecognizer:)];

    _transitionController = [[NYTPhotoTransitionController alloc] init];
    self.modalPresentationStyle = UIModalPresentationCustom;
    self.transitioningDelegate = _transitionController;
    self.modalPresentationCapturesStatusBarAppearance = YES;

    _overlayView = [[NYTPhotosOverlayView alloc] initWithFrame:CGRectZero];
    UIImage *image = [[UIImage imageNamed:@"NYTPhotoViewerCloseButton" inBundle:[NSBundle nyt_photoViewerResourceBundle] compatibleWithTraitCollection:nil] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    _overlayView.leftBarButtonItem = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:self action:@selector(doneButtonTapped:)];

    BOOL clientCanHandle = YES;
    if ([self.delegate respondsToSelector:@selector(photosViewController:canPerformActionButtonForPhoto:)]) {
        clientCanHandle = [self.delegate photosViewController:self canPerformActionButtonForPhoto:initialPhoto];
    }
    
    if (clientCanHandle) {
        UIImage *image = [[UIImage imageNamed:@"NYTPhotoViewerShareButton" inBundle:[NSBundle nyt_photoViewerResourceBundle] compatibleWithTraitCollection:nil] imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        _overlayView.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:image style:UIBarButtonItemStylePlain target:self action:@selector(actionButtonTapped:)];
    }

    //_notificationCenter = [[NSNotificationCenter alloc] init];
    _notificationCenter = [NSNotificationCenter defaultCenter];

    [self setupPageViewControllerWithInitialPhoto:initialPhoto];
}

- (void)setupPageViewControllerWithInitialPhoto:(id <NYTPhoto>)initialPhoto {
    self.pageViewController = [[UIPageViewController alloc] initWithTransitionStyle:UIPageViewControllerTransitionStyleScroll navigationOrientation:UIPageViewControllerNavigationOrientationHorizontal options:@{UIPageViewControllerOptionInterPageSpacingKey: @(NYTPhotosViewControllerInterPhotoSpacing)}];
    
    self.pageViewController.delegate = self;
    self.pageViewController.dataSource = self;
    
    NYTPhotoViewController *initialPhotoViewController;
    
    if ([self.dataSource containsPhoto:initialPhoto]) {
        initialPhotoViewController = [self newPhotoViewControllerForPhoto:initialPhoto];
    }
    else {
        initialPhotoViewController = [self newPhotoViewControllerForPhoto:self.dataSource[0]];
    }
    
    [self setCurrentlyDisplayedViewController:initialPhotoViewController animated:NO];
}

- (void)addOverlayView {
    NSAssert(self.overlayView != nil, @"_overlayView must be set during initialization, to provide bar button items for this %@", NSStringFromClass([self class]));

    UIColor *textColor = self.view.tintColor ?: [UIColor whiteColor];
    self.overlayView.titleTextAttributes = @{NSForegroundColorAttributeName: textColor};
    
    [self updateOverlayInformation];
    [self.view addSubview:self.overlayView];
    
    [self setOverlayViewHidden:YES animated:NO];
}


- (void)updateOverlayInformation {
    NSString *overlayTitle;
    
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:self.currentlyDisplayedPhoto];
    
    if ([self.delegate respondsToSelector:@selector(photosViewController:titleForPhoto:atIndex:totalPhotoCount:)]) {
        overlayTitle = [self.delegate photosViewController:self titleForPhoto:self.currentlyDisplayedPhoto atIndex:photoIndex totalPhotoCount:self.dataSource.numberOfPhotos];
    }
    
    if (!overlayTitle && self.dataSource.numberOfPhotos > 1) {
        NSUInteger displayIndex = 1;
        
        if (photoIndex < self.dataSource.numberOfPhotos) {
            displayIndex = photoIndex + 1;
        }

        overlayTitle = [NSString localizedStringWithFormat:NSLocalizedString(@"%lu of %lu", nil), (unsigned long)displayIndex, (unsigned long)self.dataSource.numberOfPhotos];
    }
    
    self.overlayView.title = overlayTitle;
    
    UIView *captionView;
    if ([self.delegate respondsToSelector:@selector(photosViewController:captionViewForPhoto:)]) {
        captionView = [self.delegate photosViewController:self captionViewForPhoto:self.currentlyDisplayedPhoto];
    }
    
    if (!captionView) {
        captionView = [[NYTPhotoCaptionView alloc] initWithAttributedTitle:self.currentlyDisplayedPhoto.attributedCaptionTitle attributedSummary:self.currentlyDisplayedPhoto.attributedCaptionSummary attributedCredit:self.currentlyDisplayedPhoto.attributedCaptionCredit];
    }
    
    self.overlayView.captionView = captionView;
}

- (void)doneButtonTapped:(id)sender {
    [self dismissViewControllerAnimated:YES userInitiated:YES completion:nil];
}

- (void)actionButtonTapped:(id)sender {
    BOOL clientDidHandle = NO;
    
    if ([self.delegate respondsToSelector:@selector(photosViewController:handleActionButtonTappedForPhoto:)]) {
        clientDidHandle = [self.delegate photosViewController:self handleActionButtonTappedForPhoto:self.currentlyDisplayedPhoto];
    }
    
    if (!clientDidHandle && (self.currentlyDisplayedPhoto.image || self.currentlyDisplayedPhoto.imageData)) {
        UIImage *image = self.currentlyDisplayedPhoto.image ? self.currentlyDisplayedPhoto.image : [UIImage imageWithData:self.currentlyDisplayedPhoto.imageData];
        UIActivityViewController *activityViewController = [[UIActivityViewController alloc] initWithActivityItems:@[image] applicationActivities:nil];
        activityViewController.popoverPresentationController.barButtonItem = sender;
        activityViewController.completionWithItemsHandler = ^(NSString * __nullable activityType, BOOL completed, NSArray * __nullable returnedItems, NSError * __nullable activityError) {
            if (completed && [self.delegate respondsToSelector:@selector(photosViewController:actionCompletedWithActivityType:)]) {
                [self.delegate photosViewController:self actionCompletedWithActivityType:activityType];
            }
        };

        [self displayActivityViewController:activityViewController animated:YES];
    }
}

- (void)displayActivityViewController:(UIActivityViewController *)controller animated:(BOOL)animated {

    if (UI_USER_INTERFACE_IDIOM() == UIUserInterfaceIdiomPhone) {
        [self presentViewController:controller animated:animated completion:nil];
    }
    else {
        controller.popoverPresentationController.barButtonItem = self.rightBarButtonItem;
        [self presentViewController:controller animated:animated completion:nil];
    }
}

- (UIBarButtonItem *)leftBarButtonItem {
    return self.overlayView.leftBarButtonItem;
}

- (void)setLeftBarButtonItem:(UIBarButtonItem *)leftBarButtonItem {
    self.overlayView.leftBarButtonItem = leftBarButtonItem;
}

- (NSArray *)leftBarButtonItems {
    return self.overlayView.leftBarButtonItems;
}

- (void)setLeftBarButtonItems:(NSArray *)leftBarButtonItems {
    self.overlayView.leftBarButtonItems = leftBarButtonItems;
}

- (UIBarButtonItem *)rightBarButtonItem {
    return self.overlayView.rightBarButtonItem;
}

- (void)setRightBarButtonItem:(UIBarButtonItem *)rightBarButtonItem {
    self.overlayView.rightBarButtonItem = rightBarButtonItem;
}

- (NSArray *)rightBarButtonItems {
    return self.overlayView.rightBarButtonItems;
}

- (void)setRightBarButtonItems:(NSArray *)rightBarButtonItems {
    self.overlayView.rightBarButtonItems = rightBarButtonItems;
}

- (void)displayPhoto:(id <NYTPhoto>)photo animated:(BOOL)animated {
    if (![self.dataSource containsPhoto:photo]) {
        return;
    }
    
    NYTPhotoViewController *photoViewController = [self newPhotoViewControllerForPhoto:photo];
    [self setCurrentlyDisplayedViewController:photoViewController animated:animated];
    [self updateOverlayInformation];
}

- (void)updateImageForPhoto:(id <NYTPhoto>)photo {
    [self.notificationCenter postNotificationName:NYTPhotoViewControllerPhotoImageUpdatedNotification object:photo];
}

#pragma mark - Gesture Recognizers

- (void)didSingleTapWithGestureRecognizer:(UITapGestureRecognizer *)tapGestureRecognizer {
    [self setOverlayViewHidden:!self.overlayView.hidden animated:YES];
}

- (void)didPanWithGestureRecognizer:(UIPanGestureRecognizer *)panGestureRecognizer {
    if (panGestureRecognizer.state == UIGestureRecognizerStateBegan) {
        self.transitionController.forcesNonInteractiveDismissal = NO;
        [self dismissViewControllerAnimated:YES userInitiated:YES completion:nil];
    }
    else {
        self.transitionController.forcesNonInteractiveDismissal = YES;
        [self.transitionController didPanWithPanGestureRecognizer:panGestureRecognizer viewToPan:self.pageViewController.view anchorPoint:self.boundsCenterPoint];
    }
}

#pragma mark - View Controller Dismissal
    
- (void)dismissViewControllerAnimated:(BOOL)animated userInitiated:(BOOL)isUserInitiated completion:(void (^)(void))completion {
    if (self.presentedViewController) {
        [super dismissViewControllerAnimated:animated completion:completion];
        return;
    }
    
    UIView *startingView;
    if (self.currentlyDisplayedPhoto.image || self.currentlyDisplayedPhoto.placeholderImage || self.currentlyDisplayedPhoto.imageData) {
        startingView = self.currentPhotoViewController.scalingImageView.imageView;
    }
    
    self.transitionController.startingView = startingView;
    self.transitionController.endingView = self.referenceViewForCurrentPhoto;

    self.overlayWasHiddenBeforeTransition = self.overlayView.hidden;
    [self setOverlayViewHidden:YES animated:animated];

    // Cocoa convention is not to call delegate methods when you do something directly in code,
    // so we'll not call delegate methods if this is a programmatic dismissal:
    BOOL const shouldSendDelegateMessages = isUserInitiated;
    
    if (shouldSendDelegateMessages && [self.delegate respondsToSelector:@selector(photosViewControllerWillDismiss:)]) {
        [self.delegate photosViewControllerWillDismiss:self];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:NYTPhotosViewControllerWillDismissNotification object:self];
    
    [super dismissViewControllerAnimated:animated completion:^{
        BOOL isStillOnscreen = self.view.window != nil; // Happens when the dismissal is canceled.
        
        if (isStillOnscreen && !self.overlayWasHiddenBeforeTransition) {
            [self setOverlayViewHidden:NO animated:YES];
        }
        
        if (!isStillOnscreen) {
            if (shouldSendDelegateMessages && [self.delegate respondsToSelector:@selector(photosViewControllerDidDismiss:)]) {
                [self.delegate photosViewControllerDidDismiss:self];
            }
            
            [[NSNotificationCenter defaultCenter] postNotificationName:NYTPhotosViewControllerDidDismissNotification object:self];
        }

        if (completion) {
            completion();
        }
    }];
}

#pragma mark - Convenience

- (void)setCurrentlyDisplayedViewController:(UIViewController <NYTPhotoContainer> *)viewController animated:(BOOL)animated {
    if (!viewController) {
        return;
    }
    
    [self.pageViewController setViewControllers:@[viewController] direction:UIPageViewControllerNavigationDirectionForward animated:animated completion:nil];
}

- (void)setOverlayViewHidden:(BOOL)hidden animated:(BOOL)animated {
    if (hidden == self.overlayView.hidden) {
        return;
    }
    
    if (animated) {
        self.overlayView.hidden = NO;
        
        self.overlayView.alpha = hidden ? 1.0 : 0.0;
        
        [UIView animateWithDuration:NYTPhotosViewControllerOverlayAnimationDuration delay:0.0 options:UIViewAnimationOptionCurveEaseInOut | UIViewAnimationOptionAllowAnimatedContent | UIViewAnimationOptionAllowUserInteraction animations:^{
            self.overlayView.alpha = hidden ? 0.0 : 1.0;
        } completion:^(BOOL finished) {
            self.overlayView.alpha = 1.0;
            self.overlayView.hidden = hidden;
        }];
    }
    else {
        self.overlayView.hidden = hidden;
    }
}

- (NYTPhotoViewController *)newPhotoViewControllerForPhoto:(id <NYTPhoto>)photo {
    if (photo) {
        UIView *loadingView;
        if ([self.delegate respondsToSelector:@selector(photosViewController:loadingViewForPhoto:)]) {
            loadingView = [self.delegate photosViewController:self loadingViewForPhoto:photo];
        }
        
        NYTPhotoViewController *photoViewController = [[NYTPhotoViewController alloc] initWithPhoto:photo loadingView:loadingView notificationCenter:self.notificationCenter];
        photoViewController.delegate = self;
        [self.singleTapGestureRecognizer requireGestureRecognizerToFail:photoViewController.doubleTapGestureRecognizer];

        if([self.delegate respondsToSelector:@selector(photosViewController:maximumZoomScaleForPhoto:)]) {
            CGFloat maximumZoomScale = [self.delegate photosViewController:self maximumZoomScaleForPhoto:photo];
            photoViewController.scalingImageView.maximumZoomScale = maximumZoomScale;
        }

        return photoViewController;
    }
    
    return nil;
}

- (void)didNavigateToPhoto:(id <NYTPhoto>)photo {
    if ([self.delegate respondsToSelector:@selector(photosViewController:didNavigateToPhoto:atIndex:)]) {
        [self.delegate photosViewController:self didNavigateToPhoto:photo atIndex:[self.dataSource indexOfPhoto:photo]];
    }
    
    [[NSNotificationCenter defaultCenter] postNotificationName:NYTPhotosViewControllerDidNavigateToPhotoNotification object:self];
}

- (id <NYTPhoto>)currentlyDisplayedPhoto {
    return self.currentPhotoViewController.photo;
}

- (NYTPhotoViewController *)currentPhotoViewController {
    return self.pageViewController.viewControllers.firstObject;
}

- (UIView *)referenceViewForCurrentPhoto {
    if ([self.delegate respondsToSelector:@selector(photosViewController:referenceViewForPhoto:)]) {
        return [self.delegate photosViewController:self referenceViewForPhoto:self.currentlyDisplayedPhoto];
    }
    
    return nil;
}

- (CGPoint)boundsCenterPoint {
    return CGPointMake(CGRectGetMidX(self.view.bounds), CGRectGetMidY(self.view.bounds));
}

// Make sure this device is an iPhone 6 or greater or iPad Air 2 or greater
- (BOOL)checkValidDeviceModel {
    struct utsname systemInfo;
    uname(&systemInfo);

    NSString *deviceModel = [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
    if ([deviceModel hasPrefix:@"iPhone"] && deviceModel.length > 7) {
        NSString *s = [deviceModel substringWithRange:NSMakeRange(6, 1)];
        // iPhone 6 or greater
        if (s.integerValue >= 7) {
            return YES;
        }
    } else if ([deviceModel hasPrefix:@"iPad"] && deviceModel.length > 5) {
        NSString *s = [deviceModel substringWithRange:NSMakeRange(4, 1)];
        // iPad Air or greater
        if (s.integerValue >= 4) {
            return YES;
        }
    }
#if DEBUG
    if ([deviceModel hasPrefix:@"x86_"]) {
        return YES;
    }
#endif
    return NO;
}

#pragma mark - NYTPhotoViewControllerDelegate

- (void)photoViewController:(NYTPhotoViewController *)photoViewController didLongPressWithGestureRecognizer:(UILongPressGestureRecognizer *)longPressGestureRecognizer {
    self.shouldHandleLongPress = NO;
    
    BOOL clientDidHandle = NO;
    if ([self.delegate respondsToSelector:@selector(photosViewController:handleLongPressForPhoto:withGestureRecognizer:)]) {
        clientDidHandle = [self.delegate photosViewController:self handleLongPressForPhoto:photoViewController.photo withGestureRecognizer:longPressGestureRecognizer];
    }
    
    self.shouldHandleLongPress = !clientDidHandle;
    
    if (self.shouldHandleLongPress) {
        UIMenuController *menuController = [UIMenuController sharedMenuController];
        CGRect targetRect = CGRectZero;
        targetRect.origin = [longPressGestureRecognizer locationInView:longPressGestureRecognizer.view];
        [menuController setTargetRect:targetRect inView:longPressGestureRecognizer.view];
        // Allow save image
        UIMenuItem *menuItem = [[UIMenuItem alloc] initWithTitle:@"Save" action:@selector(saveImage:)];
        [menuController setMenuItems:@[ menuItem ]];
        [menuController setMenuVisible:YES animated:YES];
    }
}

#pragma mark - UIPageViewControllerDataSource

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerBeforeViewController:(UIViewController <NYTPhotoContainer> *)viewController {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:viewController.photo];
    return [self newPhotoViewControllerForPhoto:self.dataSource[photoIndex - 1]];
}

- (UIViewController *)pageViewController:(UIPageViewController *)pageViewController viewControllerAfterViewController:(UIViewController <NYTPhotoContainer> *)viewController {
    NSUInteger photoIndex = [self.dataSource indexOfPhoto:viewController.photo];
    return [self newPhotoViewControllerForPhoto:self.dataSource[photoIndex + 1]];
}

#pragma mark - UIPageViewControllerDelegate

- (void)pageViewController:(UIPageViewController *)pageViewController didFinishAnimating:(BOOL)finished previousViewControllers:(NSArray *)previousViewControllers transitionCompleted:(BOOL)completed {
    if (completed) {
        [self updateOverlayInformation];
        
        UIViewController <NYTPhotoContainer> *photoViewController = pageViewController.viewControllers.firstObject;
        [self didNavigateToPhoto:photoViewController.photo];
    }
}

@end
