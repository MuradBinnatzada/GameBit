import 'package:flutter/material.dart';

import 'package:checkpoint/state/app_stores.dart';
import 'package:checkpoint/state/auth_store.dart';
import 'package:checkpoint/state/blocks_store.dart';
import 'package:checkpoint/state/browse_store.dart';
import 'package:checkpoint/state/community_times_store.dart';
import 'package:checkpoint/state/discussions_store.dart';
import 'package:checkpoint/state/company_store.dart';
import 'package:checkpoint/state/friends_feed_store.dart';
import 'package:checkpoint/state/game_details_store.dart';
import 'package:checkpoint/state/game_friends_store.dart';
import 'package:checkpoint/state/game_reviews_store.dart';
import 'package:checkpoint/state/library_attributes_store.dart';
import 'package:checkpoint/state/library_store.dart';
import 'package:checkpoint/state/library_view_store.dart';
import 'package:checkpoint/state/lists_store.dart';
import 'package:checkpoint/state/milestones_store.dart';
import 'package:checkpoint/state/nav_store.dart';
import 'package:checkpoint/state/news_store.dart';
import 'package:checkpoint/state/play_timer_store.dart';
import 'package:checkpoint/state/profile_store.dart';
import 'package:checkpoint/state/public_achievements_store.dart';
import 'package:checkpoint/state/public_library_store.dart';
import 'package:checkpoint/state/public_profile_store.dart';
import 'package:checkpoint/state/release_alerts_store.dart';
import 'package:checkpoint/state/search_store.dart';
import 'package:checkpoint/state/shared_link_store.dart';
import 'package:checkpoint/state/social_graph_store.dart';

/// Makes one store available to the widgets below it. There is one scope per
/// store, each rebuilding only the widgets that [StoreContext.watch] that store,
/// so a search result arriving doesn't rebuild the Library tab.
class StoreScope<T extends ChangeNotifier> extends InheritedNotifier<T> {
  const StoreScope({super.key, required T store, required super.child})
      : super(notifier: store);
}

extension StoreContext on BuildContext {
  /// The [T] store, subscribing the caller to its changes. For `build`.
  T watch<T extends ChangeNotifier>() {
    final scope = dependOnInheritedWidgetOfExactType<StoreScope<T>>();
    assert(scope != null, 'No StoreScope<$T> above this context.');
    return scope!.notifier!;
  }

  /// The [T] store with no subscription: for event handlers and `initState`.
  T read<T extends ChangeNotifier>() {
    final element = getElementForInheritedWidgetOfExactType<StoreScope<T>>();
    assert(element != null, 'No StoreScope<$T> above this context.');
    return (element!.widget as StoreScope<T>).notifier!;
  }
}

/// Provides every store of [stores] to [child]. It sits above `MaterialApp` so
/// pushed routes and sheets can reach them.
class AppStoresScope extends StatelessWidget {
  const AppStoresScope({super.key, required this.stores, required this.child});

  final AppStores stores;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return StoreScope<AuthStore>(
      store: stores.auth,
      child: StoreScope<NavStore>(
        store: stores.nav,
        child: StoreScope<ProfileStore>(
          store: stores.profile,
          child: StoreScope<LibraryStore>(
            store: stores.library,
            child: StoreScope<LibraryViewStore>(
              store: stores.libraryView,
              child: StoreScope<SearchStore>(
                store: stores.search,
                child: StoreScope<BrowseStore>(
                  store: stores.browse,
                  child: StoreScope<PublicProfileStore>(
                    store: stores.publicProfiles,
                    child: StoreScope<PublicLibraryStore>(
                      store: stores.publicLibraries,
                      child: StoreScope<SocialGraphStore>(
                        store: stores.socialGraph,
                        child: StoreScope<PublicAchievementsStore>(
                          store: stores.publicAchievements,
                          child: StoreScope<GameDetailsStore>(
                            store: stores.gameDetails,
                            child: StoreScope<LibraryAttributesStore>(
                              store: stores.libraryAttributes,
                              child: StoreScope<GameFriendsStore>(
                                store: stores.gameFriends,
                                child: StoreScope<CompanyStore>(
                                  store: stores.companies,
                                  child: StoreScope<FriendsFeedStore>(
                                    store: stores.friendsFeed,
                                    child: StoreScope<PlayTimerStore>(
                                      store: stores.playTimer,
                                      child: StoreScope<ListsStore>(
                                        store: stores.lists,
                                        child: StoreScope<ReleaseAlertsStore>(
                                          store: stores.releaseAlerts,
                                          child: StoreScope<SharedLinkStore>(
                                            store: stores.links,
                                            child: StoreScope<CommunityTimesStore>(
                                              store: stores.communityTimes,
                                              child: StoreScope<MilestonesStore>(
                                                store: stores.milestones,
                                                child: StoreScope<GameReviewsStore>(
                                                  store: stores.gameReviews,
                                                  child: StoreScope<NewsStore>(
                                                    store: stores.news,
                                                    child: StoreScope<DiscussionsStore>(
                                                      store: stores.discussions,
                                                      child: StoreScope<BlocksStore>(
                                                        store: stores.blocks,
                                                        child: child,
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
